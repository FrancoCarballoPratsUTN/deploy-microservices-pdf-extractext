#!/usr/bin/env bash
#
# Test del patrón circuit breaker (middleware extract-cb) del tramo E-W.
#
# El breaker abre cuando la ratio de errores (red o 5xx) supera 0.30. Para verlo
# de forma determinista se detiene el MS Extract real y se lo reemplaza por un
# stub que SIEMPRE responde 502 (servidor presente pero fallando). Las primeras
# peticiones dan 502 y, apenas la ratio supera el umbral, Traefik cortocircuita
# y empieza a devolver 503. Al final se restaura el servicio real y se comprueba
# que el sistema se recupera (200).
#
# Nota: se llama directo al entrypoint interno (http://traefik-internal:8443,
# E-W) para aislar el breaker del dedup del orquestador.
#
# Uso:  make test-cb   (o ./tests/04-circuit-breaker.sh desde deploy/)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_stack

PDF="$CORPUS_PDF"

cleanup() {
  cleanup_stub
  docker compose up -d extract >/dev/null 2>&1
  docker compose restart traefik-internal >/dev/null 2>&1
}
trap cleanup EXIT

section "Circuit breaker (extract-cb): servidor presente pero fallando"
echo "  deteniendo extract real y arrancando stub que siempre responde 502..."
mapfile -t extract_ids < <(compose_service_ids extract)
docker compose stop extract >/dev/null 2>&1
# Extract se quita del agente al recibir SIGTERM, pero el catálogo puede
# conservar la entrada replicada. Limpiamos sólo los IDs de los contenedores
# detenidos antes de arrancar el stub.
catalog_deregister_ids extract "${extract_ids[@]}"
for _ in $(seq 1 30); do
  [[ "$(consul_count extract)" == "0" ]] && break
  sleep 1
done
if [[ "$(consul_count extract)" != "0" ]]; then
  echo "ERROR: Consul todavía anuncia instancias de extract después de limpiar el catálogo." >&2
  exit 1
fi
start_stub extract 8080 9999

statuses=()
for _ in $(seq 1 20); do
  code="$(ew POST /extract)"
  statuses+=("$code")
  [[ "$code" == "503" ]] && break
  sleep 0.3
done
echo "  secuencia de status E-W /extract: ${statuses[*]}"

joined="$(printf '%s\n' "${statuses[@]}")"
c502="$(printf '%s\n' "$joined" | grep -c '^502$' || true)"
c503="$(printf '%s\n' "$joined" | grep -c '^503$' || true)"
assert_ge "hubo 502 (upstream fallando, breaker cerrado)" 1 "$c502"
assert_ge "hubo 503 (circuito ABIERTO)" 1 "$c503"

section "Recuperación tras restaurar el servicio real"
cleanup_stub
docker compose up -d extract >/dev/null 2>&1
if wait_healthy extract 120; then ok "extract volvió healthy"; else ko "extract no volvió healthy"; fi
docker compose restart traefik-internal >/dev/null 2>&1
wait_healthy traefik-internal 60 >/dev/null 2>&1 || true

# `wait_healthy` sólo confirma que el contenedor está healthy. Consul Catalog
# y Traefik todavía pueden tardar en volver a descubrir los extract levantados;
# durante esa ventana la petición E-W puede fallar a nivel de conexión (status 0).
recovery_code=0
for _ in $(seq 1 60); do
  if [[ "$(consul_count extract)" =~ ^[1-9][0-9]*$ ]]; then
    recovery_code="$(ew POST /extract "$PDF")"
    [[ "$recovery_code" == "200" ]] && break
  fi
  sleep 2
done
assert_status "E-W POST /extract con PDF real (recuperado)" "200" "$recovery_code"

summary
