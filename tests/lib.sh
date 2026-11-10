#!/usr/bin/env bash
#
# Librería compartida por los tests de usuario del deploy (Fase 11).
#
# Se hace `source` desde cada test. Define helpers de aserción, clientes HTTP
# (borde N-S con curl y tramo E-W con un contenedor efímero) y utilidades de
# Docker/Compose, de modo que cada test sea legible y consistente.
#
# Convenciones:
#   - Se ejecuta desde deploy/tests/<test>.sh; lib.sh resuelve DEPLOY_DIR como
#     el directorio padre y hace `cd` ahí (todas las rutas del deploy son
#     relativas a deploy/).
#   - Las aserciones NUNCA abortan el test: cuentan PASS/FAIL y al final el
#     test llama a `summary`.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$TESTS_DIR/.." && pwd)"
cd "$DEPLOY_DIR"

# --- Configuración (override por entorno) --------------------------------
# Se carga deploy/.env antes de resolver los defaults para que las credenciales
# de Consul estén disponibles en los tests.
if [[ -f "$DEPLOY_DIR/.env" ]]; then
  set -a; . "$DEPLOY_DIR/.env"; set +a
fi

CACERT="${CACERT:-certs/rootCA.pem}"
HOSTNAME_="${HOSTNAME_:-pdf-extractext.localhost}"
BASE="${BASE:-https://${HOSTNAME_}}"
NETWORK="${NETWORK:-pdf-extractext_backend}"
CLIENT_IMAGE="${CLIENT_IMAGE:-python:3.14-slim}"
STUB_IMAGE="${STUB_IMAGE:-python:3.14-slim}"
STUB_NAME="${STUB_NAME:-pattern-stub}"
CORPUS="${CORPUS:-../extract-markdown-microservice-pdf-extractext/tests/stress/pdfs/2020-Scrum-Guide-Spanish-Latin-South-American.pdf}"
CORPUS_PDF="$(cd "$(dirname "$CORPUS")" 2>/dev/null && pwd)/$(basename "$CORPUS")"

# --- Consul (API interna vía docker exec) ---------------------------------
# Consul corre solo en la red privada, sin puertos publicados. Los tests/scripts
# acceden a su API desde el contenedor `consul`.
CONSUL_CONTAINER="${CONSUL_CONTAINER:-consul}"
CONSUL_LOCAL_URL="${CONSUL_LOCAL_URL:-https://127.0.0.1:8501}"
CONSUL_LOCAL_CA="${CONSUL_LOCAL_CA:-/consul/config/tls/consul-ca.pem}"
CONSUL_READ_TOKEN="${CONSUL_READ_TOKEN:-${CONSUL_TRAEFIK_TOKEN:-}}"

# --- Colores --------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_RESET=$'\033[0m'
else
  C_RED=; C_GREEN=; C_YELLOW=; C_CYAN=; C_RESET=
fi

PASS=0
FAIL=0

section() { echo; echo "${C_CYAN}== $* ==${C_RESET}"; }
ok()   { echo "  ${C_GREEN}ok${C_RESET}   $*"; PASS=$((PASS + 1)); }
ko()   { echo "  ${C_RED}FAIL${C_RESET} $*" >&2; FAIL=$((FAIL + 1)); }

assert_eq() { # <desc> <esperado> <obtenido>
  if [[ "$2" == "$3" ]]; then ok "$1 (esperado=$2 obtenido=$3)"; else ko "$1 (esperado=$2 obtenido=$3)"; fi
}

assert_status() { # <desc> <esperados separados por |> <obtenido>
  if [[ "$3" =~ ^($2)$ ]]; then ok "$1 (HTTP $3)"; else ko "$1 (esperado HTTP $2, obtenido $3)"; fi
}

assert_contains() { # <desc> <aguja> <pajar>
  if [[ "$3" == *"$2"* ]]; then ok "$1"; else ko "$1 (no contiene '$2')"; fi
}

assert_not_contains() { # <desc> <aguja> <pajar>
  if [[ "$3" != *"$2"* ]]; then ok "$1"; else ko "$1 (no debería contener '$2')"; fi
}

assert_ge() { # <desc> <min> <actual>
  if [[ "$3" =~ ^-?[0-9]+$ ]] && (( $3 >= $2 )); then ok "$1 ($3 >= $2)"; else ko "$1 (esperado >= $2, obtenido '$3')"; fi
}

# --- Cliente del borde N-S (curl con la CA de dev) ------------------------
CURL_BASE=(curl -sS --cacert "$CACERT" --resolve "${HOSTNAME_}:443:127.0.0.1")

api_code() { # <method> <path> [curl args...] -> imprime el status
  local m="$1" p="$2"; shift 2
  "${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' -X "$m" "${BASE}${p}" "$@"
}

api_body() { # <method> <path> [curl args...] -> imprime el cuerpo
  local m="$1" p="$2"; shift 2
  "${CURL_BASE[@]}" -X "$m" "${BASE}${p}" "$@"
}

api_headers() { # <method> <path> [curl args...] -> imprime headers + cuerpo
  local m="$1" p="$2"; shift 2
  "${CURL_BASE[@]}" -i -X "$m" "${BASE}${p}" "$@"
}

# Hace una request y deja el cuerpo en RESP_BODY y el status en RESP_CODE.
RESP_BODY=""; RESP_CODE=""
api_req() { # <method> <path> [curl args...]
  local m="$1" p="$2"; shift 2
  local out
  out="$("${CURL_BASE[@]}" -X "$m" "${BASE}${p}" -w $'\n%{http_code}' "$@")"
  RESP_CODE="${out##*$'\n'}"
  RESP_BODY="${out%$'\n'*}"
}

# Redirige cualquier host (sin verificar cert) para probar ruteo por Host.
raw_code() { curl -sS -o /dev/null -w '%{http_code}' "$@"; }

# --- Cliente del tramo E-W (entrypoint interno http://traefik-internal:8443) ---
# Corre un contenedor efímero dentro de la red `backend` para resolver el DNS
# `traefik-internal`. Opcionalmente monta un archivo local como cuerpo (a /in.pdf).
_EW_PY='
import os, sys, urllib.request, urllib.error
method, path = sys.argv[1], sys.argv[2]
data, headers = None, {}
f = os.environ.get("EWFILE")
if f:
    data = open(f, "rb").read()
    headers["Content-Type"] = "application/pdf"
elif method in ("POST", "PUT", "PATCH"):
    data = b"x"
req = urllib.request.Request("http://traefik-internal:8443" + path, data=data, method=method, headers=headers)
try:
    r = urllib.request.urlopen(req, timeout=40)
    print(r.status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print(0)
'

ew() { # <method> <path> [localfile] -> imprime el status HTTP
  local method="$1" path="$2" file="${3:-}" args=()
  if [[ -n "$file" ]]; then
    args=(-v "$(readlink -f "$file"):/in.pdf:ro" -e EWFILE=/in.pdf)
  fi
  docker run --rm --network "$NETWORK" "${args[@]}" \
    --entrypoint python3 "$CLIENT_IMAGE" -c "$_EW_PY" "$method" "$path"
}

# --- Stub de fallo intermitente (para retry y circuit breaker) ------------
# Traefik descubre los servicios por Consul Catalog (no por el provider Docker),
# así que el stub se registra como una instancia más del servicio en Consul,
# apuntando a la IP del contenedor dentro de la red `backend`.
consul_api() { # <method> <path> [json] [token]
  local m="$1" p="$2" data="${3:-}" token="${4:-$CONSUL_READ_TOKEN}"
  local args=(exec -i "$CONSUL_CONTAINER" curl -fsS --cacert "$CONSUL_LOCAL_CA" -H "X-Consul-Token: $token" -X "$m")
  if [[ -n "$data" ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary @-)
    printf '%s' "$data" | docker "${args[@]}" "$CONSUL_LOCAL_URL$p"
  else
    docker "${args[@]}" "$CONSUL_LOCAL_URL$p"
  fi
}

_consul_put() { # <path> <json> <token>
  local p="$1" data="$2" token="$3"
  printf '%s' "$data" | docker exec -i "$CONSUL_CONTAINER" curl -fsS \
    --cacert "$CONSUL_LOCAL_CA" -H "X-Consul-Token: $token" \
    -H 'Content-Type: application/json' -X PUT --data-binary @- \
    "$CONSUL_LOCAL_URL$p"
}

cleanup_stub() {
  local service id t
  for service in extract persistence; do
    id="${STUB_NAME}-${service}"
    for t in "${CONSUL_EXTRACT_TOKEN:-}" "${CONSUL_PERSISTENCE_TOKEN:-}" "$CONSUL_READ_TOKEN"; do
      [[ -n "$t" ]] && docker exec "$CONSUL_CONTAINER" curl -fsS --cacert "$CONSUL_LOCAL_CA" \
        -H "X-Consul-Token: $t" -X PUT "$CONSUL_LOCAL_URL/v1/agent/service/deregister/$id" >/dev/null 2>&1 || true
    done
  done
  # Retirar IDs persistidos por versiones previas del test.
  for t in "${CONSUL_EXTRACT_TOKEN:-}" "${CONSUL_PERSISTENCE_TOKEN:-}" "$CONSUL_READ_TOKEN"; do
    [[ -n "$t" ]] && docker exec "$CONSUL_CONTAINER" curl -fsS --cacert "$CONSUL_LOCAL_CA" \
      -H "X-Consul-Token: $t" -X PUT "$CONSUL_LOCAL_URL/v1/agent/service/deregister/$STUB_NAME" >/dev/null 2>&1 || true
  done
  catalog_deregister_ids extract "${STUB_NAME}-extract" "$STUB_NAME" >/dev/null 2>&1 || true
  catalog_deregister_ids persistence "${STUB_NAME}-persistence" "$STUB_NAME" >/dev/null 2>&1 || true
  docker rm -f "$STUB_NAME" >/dev/null 2>&1 || true
}

# Tags del router E-W de cada servicio (gateway-internal, solo traefik-internal).
_ew_router_labels() { # <service> -> un tag "clave=valor" por línea
  case "$1" in
    extract)
      printf '%s\n' \
        'gateway-internal' \
        'traefik.http.routers.extract-ew.rule=PathPrefix(`/extract`)' \
        'traefik.http.routers.extract-ew.entrypoints=web-internal' \
        'traefik.http.routers.extract-ew.middlewares=security-headers@file,extract-cb@file,extract-retry@file'
      ;;
    persistence)
      printf '%s\n' \
        'gateway-internal' \
        'traefik.http.routers.texts-ew.rule=PathPrefix(`/texts`)' \
        'traefik.http.routers.texts-ew.entrypoints=web-internal' \
        'traefik.http.routers.texts-ew.middlewares=security-headers@file,persistence-cb@file,persistence-retry@file'
      ;;
  esac
}

start_stub() { # <service> <port> <fail_times>
  cleanup_stub
  docker run -d --rm --name "$STUB_NAME" --network "$NETWORK" \
    --no-healthcheck \
    -e "PORT=$2" -e "FAIL_TIMES=$3" \
    -v "$DEPLOY_DIR/scripts/retry-stub.py:/stub.py:ro" \
    --entrypoint python3 "$STUB_IMAGE" /stub.py >/dev/null

  local ip token tags=() l payload code
  ip="$(docker inspect -f "{{with index .NetworkSettings.Networks \"$NETWORK\"}}{{.IPAddress}}{{end}}" "$STUB_NAME")"
  tags=('traefik.enable=true')
  while IFS= read -r l; do [[ -n "$l" ]] && tags+=("$l"); done \
    < <(_ew_router_labels "$1")

  case "$1" in
    extract)     token="${CONSUL_EXTRACT_TOKEN:-$CONSUL_READ_TOKEN}" ;;
    persistence) token="${CONSUL_PERSISTENCE_TOKEN:-$CONSUL_READ_TOKEN}" ;;
    *)           token="$CONSUL_READ_TOKEN" ;;
  esac

  payload="$(python3 -c '
import json, sys
service, sid, addr, port = sys.argv[1:5]
print(json.dumps({"ID": sid, "Name": service, "Address": addr,
                  "Port": int(port), "Tags": sys.argv[5:]}))
' "$1" "${STUB_NAME}-$1" "$ip" "$2" "${tags[@]}")"

  code="$(printf '%s' "$payload" | docker exec -i "$CONSUL_CONTAINER" curl -fsS \
    --cacert "$CONSUL_LOCAL_CA" -H "X-Consul-Token: $token" \
    -H 'Content-Type: application/json' -o /dev/null -w '%{http_code}' \
    -X PUT --data-binary @- "$CONSUL_LOCAL_URL/v1/agent/service/register")"
  if [[ "$code" != "200" ]]; then
    echo "${C_RED}ERROR${C_RESET}: no se pudo registrar el stub en Consul (HTTP $code)" >&2
    return 1
  fi
  sleep 5 # dar tiempo al provider Consul Catalog de Traefik
}

consul_count() { # <service> -> cantidad de instancias en el catálogo
  consul_api GET "/v1/health/service/$1" \
    | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null \
    || echo 0
}

compose_service_ids() { # <compose-service> -> IDs Consul esperados, uno por línea
  local service="$1" container hostname
  while IFS= read -r container; do
    [[ -n "$container" ]] || continue
    hostname="$(docker inspect -f '{{.Config.Hostname}}' "$container")"
    printf '%s-%s\n' "$service" "$hostname"
  done < <(docker compose ps -q "$service")
}

# Consul can remove a registration from the local agent before its catalog view
# catches up. Tests that replace all replicas remove only their stopped IDs from
# the catalog so Traefik cannot keep routing to them during the fixture.
catalog_deregister_ids() { # <service> <ID>...
  local service="$1" token catalog entry payload response code
  shift
  (( $# > 0 )) || return 0

  case "$service" in
    extract) token="${CONSUL_EXTRACT_TOKEN:-$CONSUL_READ_TOKEN}" ;;
    persistence) token="${CONSUL_PERSISTENCE_TOKEN:-$CONSUL_READ_TOKEN}" ;;
    *) echo "ERROR: no hay token de deregistro para '$service'" >&2; return 1 ;;
  esac

  catalog="$(consul_api GET "/v1/catalog/service/$service")"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    payload="$(printf '%s' "$entry" | python3 -c '
import json,sys
item=json.load(sys.stdin)
print(json.dumps({"Node": item["Node"], "ServiceID": item["ServiceID"],
                  "Datacenter": item.get("Datacenter", "")}, separators=(",", ":")))
')"
    response="$(printf '%s' "$payload" | docker exec -i "$CONSUL_CONTAINER" curl -fsS \
      --cacert "$CONSUL_LOCAL_CA" -H "X-Consul-Token: $token" \
      -H 'Content-Type: application/json' -X PUT --data-binary @- \
      -w $'\n%{http_code}' "$CONSUL_LOCAL_URL/v1/catalog/deregister")"
    code="${response##*$'\n'}"
    if [[ "$code" != "200" ]]; then
      echo "ERROR: no se pudo quitar '$service' del catálogo de Consul (HTTP $code)." >&2
      echo "       El token necesita permisos para deregistrar el nodo y el servicio." >&2
      return 1
    fi
    echo "  Consul: quitado del catálogo $service/$(printf '%s' "$entry" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ServiceID"])')"
  done < <(printf '%s' "$catalog" | python3 -c '
import json,sys
entries=json.load(sys.stdin)
expected=set(sys.argv[1:])
for item in entries:
    if item.get("ServiceID") in expected:
        print(json.dumps(item, separators=(",", ":")))
' "$@")
}

stub_attempts() { # [method path] -> intentos globales o para método/ruta
  local method="${1:-}" path="${2:-}"
  if [[ -n "$method" && -n "$path" ]]; then
    docker logs "$STUB_NAME" 2>&1 \
      | grep -F "STUB $method $path " \
      | grep -c 'attempt=' || true
  else
    docker logs "$STUB_NAME" 2>&1 | grep -c 'attempt=' || true
  fi
}

# --- Docker / Compose -----------------------------------------------------
wait_healthy() { # <servicio> [timeout_s]
  local svc="$1" timeout="${2:-120}" start=$SECONDS ids all st cid
  while :; do
    mapfile -t ids < <(docker compose ps -q "$svc" 2>/dev/null)
    if (( ${#ids[@]} > 0 )); then
      all=1
      for cid in "${ids[@]}"; do
        st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo unknown)"
        [[ "$st" == "healthy" || "$st" == "running" ]] || all=0
      done
      (( all == 1 )) && return 0
    fi
    (( SECONDS - start >= timeout )) && return 1
    sleep 2
  done
}

service_containers() { docker compose ps -q "$1" 2>/dev/null; }

require_stack() {
  if [[ -z "$(docker compose ps -q orchestrator 2>/dev/null)" ]]; then
    echo "${C_RED}ERROR${C_RESET}: el stack no está arriba. Corré 'make up' en deploy/ primero." >&2
    exit 2
  fi
  if [[ ! -f "$CACERT" ]]; then
    echo "${C_RED}ERROR${C_RESET}: falta $CACERT. Corré 'make certs'." >&2
    exit 2
  fi
  if ! docker inspect "$CONSUL_CONTAINER" >/dev/null 2>&1; then
    echo "${C_RED}ERROR${C_RESET}: el contenedor Consul '$CONSUL_CONTAINER' no está corriendo." >&2
    exit 2
  fi
}

mongo_count() { # <db> <collection>
  docker compose exec -T mongo mongosh --quiet --eval \
    "db.getSiblingDB('$1').$2.countDocuments()" 2>/dev/null | tr -d '[:space:]'
}

# --- Helpers JSON (usan python3 del host) ---------------------------------
json_field() { # <ruta.dotted> [default]  (lee JSON de stdin)
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    for k in sys.argv[1].split("."):
        if k == "": continue
        d = d[int(k)] if k.isdigit() else d[k]
    print(d if not isinstance(d, (dict, list)) else json.dumps(d))
except Exception:
    print(sys.argv[2] if len(sys.argv) > 2 else "")
' "$1" "${2:-}"
}

json_len() { python3 -c 'import sys, json; print(len(json.load(sys.stdin)))'; }

json_any() { # <ruta.array> <campo> <valor>  -> yes/no
  python3 -c '
import sys, json
arr, field, value = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(sys.stdin)
for k in arr.split("."):
    if k == "": continue
    d = d[int(k)] if k.isdigit() else d[k]
print("yes" if any(str(item.get(field)) == value for item in d) else "no")
' "$1" "$2" "$3"
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# --- Cierre ---------------------------------------------------------------
summary() {
  echo
  if (( FAIL == 0 )); then
    echo "${C_GREEN}RESULTADO: $PASS ok, 0 fallidos${C_RESET}"
    return 0
  fi
  echo "${C_RED}RESULTADO: $PASS ok, $FAIL fallidos${C_RESET}"
  return 1
}
