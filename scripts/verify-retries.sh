#!/usr/bin/env bash
# Verifica los retries de Traefik en el tramo E-W con un backend stub.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../tests/lib.sh"
set -euo pipefail
require_stack

restore_services() {
  cleanup_stub
  docker compose up -d extract persistence >/dev/null 2>&1
  docker compose restart traefik-internal >/dev/null 2>&1
  wait_healthy extract 120 || true
  wait_healthy persistence 120 || true
  wait_healthy traefik-internal 60 || true
}
trap restore_services EXIT

wait_deregistered() {
  local service="$1"
  for _ in $(seq 1 30); do
    [[ "$(consul_count "$service")" == "0" ]] && return 0
    sleep 1
  done

  echo "ERROR: Consul todavía anuncia instancias de '$service' después de detener el servicio." >&2
  echo "       El test necesita que el stub sea el único backend para que el resultado sea determinista." >&2
  echo "       Registros que siguen en el catálogo (ID | nodo | dirección:puerto | estado):" >&2
  consul_api GET "/v1/health/service/$service" \
    | python3 -c '
import json, sys
try:
    entries = json.load(sys.stdin)
except Exception as exc:
    print(f"       No se pudo leer el catálogo: {exc}", file=sys.stderr)
    raise SystemExit(0)
for entry in entries:
    svc = entry.get("Service", {})
    checks = entry.get("Checks", [])
    states = ",".join(check.get("Status", "unknown") for check in checks) or "sin checks"
    node = entry.get("Node", {})
    node_name = node.get("Node", "?") if isinstance(node, dict) else node
    print("       {} | {} | {}:{} | {}".format(
        svc.get("ID", "?"), node_name,
        svc.get("Address", "?"), svc.get("Port", "?"), states))
' >&2 || true
  return 1
}

section "Retry de Extract: un reintento con POST /extract"
mapfile -t extract_ids < <(compose_service_ids extract)
docker compose stop extract >/dev/null
catalog_deregister_ids extract "${extract_ids[@]}"
wait_deregistered extract
start_stub extract 8080 1
extract_code="$(ew POST /extract)"
extract_attempts="$(stub_attempts POST /extract)"
assert_status "Extract recupera el primer 502" "200" "$extract_code"
assert_eq "Extract recibió un retry" "2" "$extract_attempts"

section "Retry de Persistence: GET se reintenta, POST no"
mapfile -t persistence_ids < <(compose_service_ids persistence)
docker compose stop persistence >/dev/null
catalog_deregister_ids persistence "${persistence_ids[@]}"
wait_deregistered persistence
start_stub persistence 8000 1
get_code="$(ew GET '/texts?checksum=retry-probe')"
get_attempts="$(stub_attempts GET '/texts?checksum=retry-probe')"
assert_status "GET /texts recupera el primer 502" "200" "$get_code"
assert_eq "GET /texts recibió un retry" "2" "$get_attempts"

post_code="$(ew POST /texts)"
post_attempts="$(stub_attempts POST /texts)"
assert_status "POST /texts no reintenta" "502" "$post_code"
assert_eq "POST /texts se envió una sola vez" "1" "$post_attempts"

summary
