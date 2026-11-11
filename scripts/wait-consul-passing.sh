#!/usr/bin/env bash
#
# Espera a que los servicios estén registrados en Consul Catalog y con todos
# sus checks en `passing`, es decir, enrutables por el provider consulCatalog
# de Traefik. Lo usa `make up` para no arrancar el orquestador hasta que sus
# dependencias estén listas.
#
# Uso:
#   ./scripts/wait-consul-passing.sh [--timeout SEGUNDOS] [servicio...]
#
# Sin servicios, espera a extract, persistence y auditlog.
#
# Sale 0 cuando cada contenedor en ejecución de cada servicio tiene su ServiceID
# en `passing`. Si vence el timeout sale 1 y muestra, por servicio, si falta el
# registro (p. ej. fue deregistrado por un check crítico) o si está registrado
# pero crítico, con la salida del check.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DEPLOY_DIR"

if [[ ! -f .env ]]; then
  echo "ERROR: deploy/.env es requerido para acceder a Consul" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
. ./.env
set +a

CONSUL_CONTAINER="${CONSUL_CONTAINER:-consul}"
CONSUL_LOCAL_URL="${CONSUL_LOCAL_URL:-https://127.0.0.1:8501}"
CONSUL_LOCAL_CA="${CONSUL_LOCAL_CA:-/consul/config/tls/consul-ca.pem}"
CONSUL_READ_TOKEN="${CONSUL_READ_TOKEN:-${CONSUL_TRAEFIK_TOKEN:-}}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"
WAIT_INTERVAL="${WAIT_INTERVAL:-2}"

if [[ "${1:-}" == "--timeout" ]]; then
  if [[ -z "${2:-}" ]]; then
    echo "ERROR: --timeout requiere un valor en segundos" >&2
    exit 1
  fi
  WAIT_TIMEOUT="$2"
  shift 2
fi

SERVICES=("$@")
if (( ${#SERVICES[@]} == 0 )); then
  SERVICES=(extract persistence auditlog)
fi

if [[ -z "$CONSUL_READ_TOKEN" ]]; then
  echo "ERROR: CONSUL_TRAEFIK_TOKEN (o CONSUL_READ_TOKEN) es requerido" >&2
  exit 1
fi
if ! docker inspect "$CONSUL_CONTAINER" >/dev/null 2>&1; then
  echo "ERROR: contenedor Consul '$CONSUL_CONTAINER' no está corriendo" >&2
  exit 1
fi

consul_get() { # <path>
  docker exec "$CONSUL_CONTAINER" curl -fsS --cacert "$CONSUL_LOCAL_CA" \
    -H "X-Consul-Token: $CONSUL_READ_TOKEN" "$CONSUL_LOCAL_URL$1"
}

# ServiceIDs esperados, derivados de los contenedores que Compose tiene en
# ejecución (mismo criterio que scripts/reconcile-consul-services.sh).
expected_ids() { # <servicio>
  local service="$1" container hostname
  while IFS= read -r container; do
    [[ -n "$container" ]] || continue
    [[ "$(docker inspect -f '{{.State.Running}}' "$container")" == "true" ]] || continue
    if [[ "$service" == "auditlog" ]]; then
      printf 'auditlog\n'
    else
      hostname="$(docker inspect -f '{{.Config.Hostname}}' "$container")"
      printf '%s-%s\n' "$service" "$hostname"
    fi
  done < <(docker compose ps -q "$service" 2>/dev/null)
}

passing_ids() { # <servicio>
  consul_get "/v1/health/service/$1?passing=true" | python3 -c '
import json, sys
for entry in json.load(sys.stdin):
    print(entry["Service"]["ID"])
'
}

diagnose() { # <servicio> <id...>
  local service="$1"
  shift
  echo "  - $service:" >&2
  if ! consul_get "/v1/health/service/$service" | python3 -c '
import json, sys

service = sys.argv[1]
missing = sys.argv[2:]
entries = json.load(sys.stdin)
by_id = {entry["Service"]["ID"]: entry for entry in entries}

for service_id in missing:
    entry = by_id.get(service_id)
    if entry is None:
        print(f"      {service_id}: NO registrado en Consul")
        continue
    for check in entry.get("Checks", []):
        if not check.get("ServiceName"):
            continue
        output = (check.get("Output") or "").strip().splitlines()
        detail = output[0][:160] if output else ""
        status = check.get("Status")
        print(f"      {service_id}: check {status} -> {detail}")
' "$service" "$@"; then
    echo "      no se pudo consultar /v1/health/service/$service" >&2
  fi
}

echo ">> Consul: esperando (timeout ${WAIT_TIMEOUT}s) a que ${SERVICES[*]} estén passing"

declare -A expected=()
declare -A missing_ids=()
declare -A ready=()

for service in "${SERVICES[@]}"; do
  mapfile -t ids < <(expected_ids "$service")
  if (( ${#ids[@]} == 0 )); then
    echo "ERROR: '$service' no tiene contenedores en ejecución (docker compose ps -q $service)" >&2
    exit 1
  fi
  expected["$service"]="${ids[*]}"
done

deadline=$(( SECONDS + WAIT_TIMEOUT ))
while :; do
  all_ready=1
  for service in "${SERVICES[@]}"; do
    if [[ -n "${ready[$service]:-}" ]]; then
      continue
    fi
    read -r -a ids <<< "${expected[$service]}"
    mapfile -t passing < <(passing_ids "$service" 2>/dev/null || true)
    missing=()
    for id in "${ids[@]}"; do
      found=0
      for candidate in "${passing[@]}"; do
        if [[ "$candidate" == "$id" ]]; then
          found=1
          break
        fi
      done
      if (( ! found )); then
        missing+=("$id")
      fi
    done
    if (( ${#missing[@]} == 0 )); then
      ready["$service"]=1
      echo "   ok   $service: ${#ids[@]} instancia(s) passing"
    else
      all_ready=0
      missing_ids["$service"]="${missing[*]}"
    fi
  done

  if (( all_ready )); then
    break
  fi
  if (( SECONDS >= deadline )); then
    echo "ERROR: timeout esperando a Consul (${WAIT_TIMEOUT}s)" >&2
    for service in "${SERVICES[@]}"; do
      if [[ -n "${ready[$service]:-}" ]]; then
        continue
      fi
      read -r -a missing <<< "${missing_ids[$service]:-}"
      diagnose "$service" "${missing[@]}"
    done
    cat >&2 <<'EOF'
Sugerencia: si un servicio está corriendo pero NO registrado, Consul lo
deregistró tras un check crítico sostenido (DeregisterCriticalServiceAfter=1m)
y el registro sólo ocurre al arrancar el proceso. Reinicialo y reintentá:
  docker compose restart <servicio>
EOF
    exit 1
  fi
  sleep "$WAIT_INTERVAL"
done

echo ">> Consul: ${SERVICES[*]} en passing"
