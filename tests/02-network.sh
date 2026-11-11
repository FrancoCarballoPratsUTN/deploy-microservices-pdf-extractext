#!/usr/bin/env bash
#
# Test de hardening y aislamiento de red del deploy.
#
# Verifica la topología de dos Traefik, dos redes + puente mongo-local:
#   - red `backend` external e internal:true; red `edge` del proyecto
#   - sólo traefik-public publica 80/443; traefik-internal no publica nada
#   - mongo publica 27017 sólo en loopback (127.0.0.1:27017), para Compass,
#     vía el puente no interno mongo-local (mismo patrón que Consul)
#   - Consul corre en `backend`, sin red `mired` y con UI/API sólo en
#     loopback (127.0.0.1:8501)
#   - ningún contenedor del stack usa `mired`
#   - microservicios/mongo solo en `backend`; traefik-public en `edge` + `backend`
#   - no-new-privileges, cap_drop ALL, read_only y sin docker.sock expuesto
#
# Uso:  make test-network   (o ./tests/02-network.sh desde deploy/)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_stack

section "1) Redes"
backend_internal="$(docker network inspect "$NETWORK" --format '{{.Internal}}' 2>/dev/null)"
assert_eq "red $NETWORK internal" "true" "$backend_internal"
edge_internal="$(docker network inspect pdf-extractext_edge --format '{{.Internal}}' 2>/dev/null || echo missing)"
assert_eq "red pdf-extractext_edge no internal" "false" "$edge_internal"

for svc in orchestrator extract persistence auditlog mongo traefik-internal; do
  cid="$(service_containers "$svc" | head -1)"
  [[ -z "$cid" ]] && { ko "no hay contenedor para '$svc'"; continue; }
  nets="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$cid")"
  assert_contains "'$svc' en backend" "$NETWORK" "$nets"
  assert_not_contains "'$svc' NO en edge" "pdf-extractext_edge" "$nets"
  assert_not_contains "'$svc' NO en mired" "mired" "$nets"
done

# Excepción explícita (D12.5): mongo, además de `backend`, está en
# `mongo-local`, puente NO interno que existe sólo para publicar 27017 en
# loopback (127.0.0.1:27017, para Compass). Docker no publica puertos desde
# redes internal, de ahí ese puente. Mismo patrón que Consul (consul_local).
mongo_cid="$(service_containers mongo | head -1)"
if [[ -n "$mongo_cid" ]]; then
  mongo_nets="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$mongo_cid")"
  assert_contains "mongo en mongo-local (publicación en loopback)" "pdf-extractext_mongo-local" "$mongo_nets"
  ml_internal="$(docker network inspect pdf-extractext_mongo-local --format '{{.Internal}}' 2>/dev/null || echo missing)"
  assert_eq "red pdf-extractext_mongo-local no internal" "false" "$ml_internal"
else
  ko "no hay contenedor para 'mongo'"
fi

tp_cid="$(service_containers traefik-public | head -1)"
if [[ -n "$tp_cid" ]]; then
  tp_nets="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$tp_cid")"
  assert_contains "traefik-public en edge" "pdf-extractext_edge" "$tp_nets"
  assert_contains "traefik-public en backend" "$NETWORK" "$tp_nets"
  assert_not_contains "traefik-public NO en mired" "mired" "$tp_nets"
else
  ko "no hay contenedor para 'traefik-public'"
fi

section "2) Consul en red privada"
if docker inspect "$CONSUL_CONTAINER" >/dev/null 2>&1; then
  consul_nets="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$CONSUL_CONTAINER")"
  assert_contains "consul en backend" "$NETWORK" "$consul_nets"
  assert_not_contains "consul NO en mired" "mired" "$consul_nets"
  consul_ports="$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$CONSUL_CONTAINER")"
  # Sólo se permite la UI/API en loopback: 127.0.0.1:8501 (o [::1]:8501).
  if python3 -c 'import json,sys
d = json.loads(sys.argv[1]) or {}
allowed = lambda p, ip, hp: p == "8501/tcp" and hp == "8501" and ip in ("127.0.0.1", "::1")
bad = ["%s->%s:%s" % (p, b.get("HostIp", ""), b.get("HostPort", ""))
       for p, bs in d.items() for b in (bs or [])
       if not allowed(p, b.get("HostIp", ""), b.get("HostPort", ""))]
sys.exit(1 if bad else 0)' "$consul_ports"; then
    ok "consul sólo publica UI/API en loopback:8501"
  else
    ko "consul publica puertos no permitidos al host: $consul_ports"
  fi
else
  ko "contenedor Consul '$CONSUL_CONTAINER' no encontrado"
fi

section "3) Puertos publicados (traefik-public; mongo sólo en loopback)"
while IFS='|' read -r name ports; do
  [[ -z "$name" ]] && continue
  case "$name" in
    *traefik-public*)
      assert_contains "traefik-public publica 443" "443->" "$ports"
      assert_contains "traefik-public publica 80" "80->" "$ports"
      ;;
    *traefik-internal*)
      if [[ "$ports" == *"->"* ]]; then ko "traefik-internal publica puertos: $ports"; else ok "traefik-internal no publica puertos"; fi
      ;;
    *mongo*)
      # Excepción explícita: mongo publica 27017 sólo en loopback
      # (127.0.0.1:27017, para Compass), igual patrón que la UI de Consul.
      mongo_ports="$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$name")"
      if python3 -c 'import json,sys
d = json.loads(sys.argv[1]) or {}
allowed = lambda p, ip, hp: p == "27017/tcp" and hp == "27017" and ip in ("127.0.0.1", "::1")
bs = [(p, b) for p, lst in d.items() for b in (lst or [])]
bad = ["%s->%s:%s" % (p, b.get("HostIp", ""), b.get("HostPort", ""))
       for p, b in bs if not allowed(p, b.get("HostIp", ""), b.get("HostPort", ""))]
good = any(allowed(p, b.get("HostIp", ""), b.get("HostPort", "")) for p, b in bs)
sys.exit(0 if good and not bad else 1)' "$mongo_ports"; then
        ok "mongo publica 27017 sólo en loopback:127.0.0.1 (Compass)"
      else
        ko "mongo debe publicar 27017 sólo en loopback (127.0.0.1:27017): $mongo_ports"
      fi
      # El host debe poder abrir conexión (lo que hace Compass).
      if timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/27017' 2>/dev/null; then
        ok "host conecta a mongo en 127.0.0.1:27017 (Compass)"
      else
        ko "host NO conecta a mongo en 127.0.0.1:27017 (¿mongo-local internal o mongo caído?)"
      fi
      ;;
    *)
      if [[ "$ports" != *"->"* ]]; then
        ok "'$name' no publica puertos"
      else
        ko "'$name' publica puertos: $ports"
      fi
      ;;
  esac
done < <(docker ps --filter "name=pdf-extractext-" --format '{{.Names}}|{{.Ports}}')

section "4) Ningún servicio del stack usa mired"
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  nets="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$name")"
  assert_not_contains "'$name' fuera de mired" "mired" "$nets"
done < <(docker ps --filter "name=pdf-extractext-" --format '{{.Names}}')

section "5) Endurecimiento"
for svc in traefik-public traefik-internal orchestrator extract persistence auditlog mongo; do
  cid="$(service_containers "$svc" | head -1)"
  [[ -z "$cid" ]] && { ko "no hay contenedor para '$svc'"; continue; }
  sec="$(docker inspect -f '{{json .HostConfig.SecurityOpt}}' "$cid")"
  assert_contains "'$svc' no-new-privileges" "no-new-privileges" "$sec"
  caps="$(docker inspect -f '{{json .HostConfig.CapDrop}}' "$cid")"
  assert_contains "'$svc' cap_drop ALL" '"ALL"' "$caps"
done

for svc in traefik-public traefik-internal orchestrator extract persistence auditlog; do
  cid="$(service_containers "$svc" | head -1)"
  [[ -z "$cid" ]] && continue
  ro="$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$cid")"
  assert_eq "'$svc' read_only" "true" "$ro"
done

section "6) Socket de Docker no expuesto"
for svc in traefik-public traefik-internal; do
  cid="$(service_containers "$svc" | head -1)"
  [[ -z "$cid" ]] && { ko "no hay contenedor para '$svc'"; continue; }
  mnts="$(docker inspect -f '{{range .Mounts}}{{.Source}}:{{.Mode}} {{end}}' "$cid")"
  assert_not_contains "$svc sin docker.sock (Consul Catalog)" "/var/run/docker.sock" "$mnts"
done

summary
