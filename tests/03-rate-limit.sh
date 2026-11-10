#!/usr/bin/env bash
#
# Test del patrón rate limit del borde (middleware api-ratelimit).
#
# El router público tiene `api-ratelimit` (average 50 req/s, burst 100) por IP
# de cliente. Se dispara una ráfaga muy por encima de ese límite contra un path
# barato que Traefik rutea al orquestador (404 de "ruta no encontrada") y se
# comprueba que aparecen respuestas 429 junto con respuestas permitidas.
#
# Usa `vegeta` si está disponible; si no, cae a un generador con curl+xargs.
#
# Uso:  make test-ratelimit   (o ./tests/03-rate-limit.sh desde deploy/)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_stack

PROBE="/api/v1/__ratelimit_probe__"
RATE="${RATE:-300}"          # requests/segundo
DUR="${DUR:-4s}"             # duración (vegeta)
TOTAL="${TOTAL:-800}"        # total (fallback curl)
CONC="${CONC:-60}"           # concurrencia (fallback curl)

section "Rate limit del borde (api-ratelimit: avg 50/s, burst 100)"

if command -v vegeta >/dev/null 2>&1; then
  echo "  generando ráfaga con vegeta: ${RATE}/s durante ${DUR} -> https://127.0.0.1${PROBE}"
  report="$(echo "GET https://127.0.0.1${PROBE}" \
    | vegeta attack -rate="$RATE" -duration="$DUR" -timeout=10s -insecure \
        -header "Host: ${HOSTNAME_}" 2>/dev/null \
    | vegeta report -type=json 2>/dev/null)"
  dist="$(printf '%s' "$report" | json_field status_codes '{}')"
  n429="$(printf '%s' "$report" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status_codes",{}).get("429",0))' 2>/dev/null || echo 0)"
  total="$(printf '%s' "$report" | python3 -c 'import sys,json;print(sum(json.load(sys.stdin).get("status_codes",{}).values()))' 2>/dev/null || echo 0)"
  ok_other=$(( total - n429 ))
else
  echo "  vegeta no está; generando $TOTAL requests con curl (concurrencia $CONC)"
  export _CACERT="$CACERT" _HOST="$HOSTNAME_" _URL="${BASE}${PROBE}"
  tmp="$(mktemp)"
  seq 1 "$TOTAL" | xargs -P "$CONC" -n1 bash -c \
    'curl -sS --cacert "$_CACERT" --resolve "$_HOST:443:127.0.0.1" -o /dev/null -w "%{http_code}\n" "$_URL"' \
    >"$tmp" 2>/dev/null || true
  n429="$(grep -c '^429$' "$tmp" || true)"
  total="$(wc -l <"$tmp" | tr -d '[:space:]')"
  ok_other="$(grep -vc '^429$' "$tmp" || true)"
  dist="$(sort "$tmp" | uniq -c | tr -s ' ' | tr '\n' ' ')"
  rm -f "$tmp"
fi

echo "  distribution: ${dist:-<sin datos>}"
echo "  total=$total  429=$n429  permitidas=$ok_other"

assert_ge "hubo respuestas 429 (límite aplicado)" 1 "$n429"
assert_ge "hubo respuestas permitidas (no todo 429)" 1 "$ok_other"

summary
