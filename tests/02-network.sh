#!/usr/bin/env bash
#
# Test de hardening y aislamiento de red del deploy.
#
# Verifica la topología de dos Traefik y dos redes:
#   - red `backend` external e internal:true; red `edge` del proyecto
#   - sólo traefik-public publica 80/443; traefik-internal no publica nada
#   - Consul corre en `backend` sin puertos publicados ni red `mired`
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
  case "$consul_ports" in
    ''|'{}'|'null') ok "consul no publica puertos al host" ;;
    *) ko "consul publica puertos al host: $consul_ports" ;;
  esac
else
  ko "contenedor Consul '$CONSUL_CONTAINER' no encontrado"
fi

section "3) Puertos publicados (sólo traefik-public)"
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
