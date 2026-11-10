#!/usr/bin/env bash
# Remove registrations from this Consul node that no longer have a Compose task.
# Consul runs only on the private network; this script uses `docker exec`.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DEPLOY_DIR"

if [[ ! -f .env ]]; then
  echo "ERROR: deploy/.env is required to access Consul" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

CONSUL_CONTAINER="${CONSUL_CONTAINER:-consul}"
CONSUL_LOCAL_URL="${CONSUL_LOCAL_URL:-https://127.0.0.1:8501}"
CONSUL_LOCAL_CA="${CONSUL_LOCAL_CA:-/consul/config/tls/consul-ca.pem}"
: "${CONSUL_TRAEFIK_TOKEN:?CONSUL_TRAEFIK_TOKEN is required}"
: "${CONSUL_ORCHESTRATOR_TOKEN:?CONSUL_ORCHESTRATOR_TOKEN is required}"
: "${CONSUL_EXTRACT_TOKEN:?CONSUL_EXTRACT_TOKEN is required}"
: "${CONSUL_PERSISTENCE_TOKEN:?CONSUL_PERSISTENCE_TOKEN is required}"
: "${CONSUL_AUDIT_TOKEN:?CONSUL_AUDIT_TOKEN is required}"

if ! docker inspect "$CONSUL_CONTAINER" >/dev/null 2>&1; then
  echo "ERROR: Consul container '$CONSUL_CONTAINER' is not running" >&2
  exit 1
fi

consul_curl() { # <token> <method> <path> [extra curl args...]
  local token="$1" method="$2" path="$3"
  shift 3
  docker exec -i "$CONSUL_CONTAINER" curl -fsS --cacert "$CONSUL_LOCAL_CA" \
    -H "X-Consul-Token: $token" -X "$method" "$@" "$CONSUL_LOCAL_URL$path"
}

service_token() {
  case "$1" in
    orchestrator) printf '%s' "$CONSUL_ORCHESTRATOR_TOKEN" ;;
    extract)      printf '%s' "$CONSUL_EXTRACT_TOKEN" ;;
    persistence)  printf '%s' "$CONSUL_PERSISTENCE_TOKEN" ;;
    auditlog)     printf '%s' "$CONSUL_AUDIT_TOKEN" ;;
  esac
}

for service in orchestrator extract persistence auditlog; do
  mapfile -t containers < <(docker compose ps -q "$service")
  if (( ${#containers[@]} == 0 )); then
    echo "ERROR: no running Compose container for '$service'; skipping reconciliation" >&2
    exit 1
  fi

  expected_ids=()
  for container in "${containers[@]}"; do
    running="$(docker inspect -f '{{.State.Running}}' "$container")"
    [[ "$running" == "true" ]] || continue
    hostname="$(docker inspect -f '{{.Config.Hostname}}' "$container")"
    if [[ "$service" == "auditlog" ]]; then
      expected_ids+=(auditlog)
    else
      expected_ids+=("$service-$hostname")
    fi
  done
  if (( ${#expected_ids[@]} == 0 )); then
    echo "ERROR: '$service' has no running containers; skipping reconciliation" >&2
    exit 1
  fi

  catalog="$(consul_curl "$CONSUL_TRAEFIK_TOKEN" GET "/v1/catalog/service/$service")"
  stale="$(printf '%s' "$catalog" | python3 -c '
import json, sys
entries = json.load(sys.stdin)
expected = set(sys.argv[1:])
node = next((item.get("Node") for item in entries
             if item.get("ServiceID") in expected), None)
if not node:
    raise SystemExit("no current registration found; refusing to clean this service")
for item in entries:
    service_id = item.get("ServiceID", "")
    if item.get("Node") == node and service_id and service_id not in expected:
        print(json.dumps({
            "ServiceID": service_id,
            "Node": node,
            "Datacenter": item.get("Datacenter", ""),
        }, separators=(",", ":")))
' "${expected_ids[@]}")"

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    service_id="$(printf '%s' "$entry" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ServiceID"])')"
    echo ">> Consul: eliminando registro obsoleto $service/$service_id"
    if consul_curl "$(service_token "$service")" PUT "/v1/agent/service/deregister/$service_id" >/dev/null 2>&1; then
      continue
    fi

    # The agent may have forgotten the ID while the catalog retained it.
    payload="$(printf '%s' "$entry" | python3 -c '
import json,sys
entry=json.load(sys.stdin)
print(json.dumps({"Node": entry["Node"], "ServiceID": entry["ServiceID"],
                  "Datacenter": entry["Datacenter"]}, separators=(",", ":")))
')"
    if ! printf '%s' "$payload" | consul_curl "$(service_token "$service")" PUT \
      "/v1/catalog/deregister" -H 'Content-Type: application/json' --data-binary @- >/dev/null 2>&1; then
      echo "ERROR: Consul could not deregister $service/$service_id; check this service token's deregistration ACL" >&2
      exit 1
    fi
  done <<< "$stale"
done

# The catalog provider polls every 2s; let it load the reconciled service set.
sleep 5
