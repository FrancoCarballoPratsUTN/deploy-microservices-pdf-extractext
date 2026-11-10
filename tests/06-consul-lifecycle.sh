#!/usr/bin/env bash
#
# Verifica el ciclo de vida real de una instancia en Consul Catalog:
#   - SIGTERM: baja del agente Y del catálogo, sin limpieza manual.
#   - Instancia crítica: purga por DeregisterCriticalServiceAfter.
#   - Recuperación: una instancia actual vuelve a registrarse y queda healthy.
#
# A diferencia de los fixtures de breaker/retry, este test NO ejecuta
# /v1/catalog/deregister: una limpieza manual ocultaría el defecto de ACL.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_stack

GRACEFUL_TIMEOUT="${CONSUL_LIFECYCLE_GRACEFUL_TIMEOUT:-40}"
CRITICAL_TIMEOUT="${CONSUL_LIFECYCLE_CRITICAL_TIMEOUT:-110}"
restart_on_cleanup=0

consul_service_ids() { # <service> -> IDs presentes en el catálogo
  consul_api GET "/v1/catalog/service/$1" | python3 -c \
    'import json,sys; print("\n".join(x.get("ServiceID", "") for x in json.load(sys.stdin)))'
}

wait_catalog_count() { # <service> <expected> <timeout_s>
  local service="$1" expected="$2" timeout="$3" start=$SECONDS current
  while :; do
    current="$(consul_count "$service")"
    [[ "$current" == "$expected" ]] && return 0
    (( SECONDS - start >= timeout )) && return 1
    sleep 2
  done
}

wait_public_without_upstream() { # <timeout_s> -> imprime el último status
  local timeout="$1" start=$SECONDS code=000
  while :; do
    code="$(api_code GET '/api/v1/audit/logs?limit=1')"
    [[ "$code" == "404" || "$code" == "503" ]] && { printf '%s' "$code"; return 0; }
    (( SECONDS - start >= timeout )) && { printf '%s' "$code"; return 1; }
    sleep 1
  done
}

restore_orchestrator() {
  local cid paused
  cid="$(docker compose ps -a -q orchestrator 2>/dev/null | head -n 1)"
  paused="$(docker inspect -f '{{.State.Paused}}' "$cid" 2>/dev/null || echo false)"
  if [[ "$paused" == "true" ]]; then
    docker compose unpause orchestrator >/dev/null 2>&1 || true
    restart_on_cleanup=1
  fi
  if (( restart_on_cleanup == 1 )); then
    docker compose restart orchestrator >/dev/null 2>&1 || true
  else
    docker compose up -d orchestrator >/dev/null 2>&1 || true
  fi
  if ! wait_healthy orchestrator 90; then
    echo "ERROR: no se pudo restaurar un orchestrator healthy" >&2
  fi
}
trap restore_orchestrator EXIT

section "Consul lifecycle: estado inicial"
expected_id="$(compose_service_ids orchestrator)"
initial_ids="$(consul_service_ids orchestrator)"
assert_eq "una instancia orchestrator en Consul" "1" "$(consul_count orchestrator)"
assert_contains "Consul contiene el ID del contenedor actual" "$expected_id" "$initial_ids"

section "Baja graceful: stop quita agente y catálogo"
docker compose stop orchestrator >/dev/null 2>&1
if wait_catalog_count orchestrator 0 "$GRACEFUL_TIMEOUT"; then
  ok "stop elimina orchestrator del catálogo sin limpieza manual"
else
  ko "stop elimina orchestrator del catálogo sin limpieza manual (siguen: $(consul_service_ids orchestrator | tr '\n' ' '))"
fi
public_code="$(wait_public_without_upstream 12)"
assert_status "Traefik deja de usar el upstream detenido" "404|503" "$public_code"

section "Re-registro al levantar la instancia"
docker compose up -d orchestrator >/dev/null 2>&1
if wait_healthy orchestrator 90; then ok "orchestrator vuelve healthy"; else ko "orchestrator vuelve healthy"; fi
if wait_catalog_count orchestrator 1 "$GRACEFUL_TIMEOUT"; then
  ok "orchestrator vuelve al catálogo"
else
  ko "orchestrator vuelve al catálogo"
fi
assert_contains "Consul contiene nuevamente el ID actual" "$expected_id" "$(consul_service_ids orchestrator)"

section "Purge automática tras quedar crítico"
docker compose pause orchestrator >/dev/null 2>&1
restart_on_cleanup=1
if wait_catalog_count orchestrator 0 "$CRITICAL_TIMEOUT"; then
  ok "Consul purga la instancia crítica sin limpieza manual"
else
  ko "Consul purga la instancia crítica sin limpieza manual (siguen: $(consul_service_ids orchestrator | tr '\n' ' '))"
fi

docker compose unpause orchestrator >/dev/null 2>&1 || true
docker compose restart orchestrator >/dev/null 2>&1
restart_on_cleanup=0
if wait_healthy orchestrator 90; then ok "orchestrator se recupera tras la pausa"; else ko "orchestrator se recupera tras la pausa"; fi
if wait_catalog_count orchestrator 1 "$GRACEFUL_TIMEOUT"; then
  ok "la instancia recuperada vuelve a registrarse"
else
  ko "la instancia recuperada vuelve a registrarse"
fi
assert_contains "el registro final corresponde al contenedor actual" "$expected_id" "$(consul_service_ids orchestrator)"

summary
