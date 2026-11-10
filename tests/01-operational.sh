#!/usr/bin/env bash
#
# Test de usuario (operatividad de punta a punta) del deploy.
#
# Recorre el mismo camino que un usuario real: entra por el borde (Traefik N-S),
# sube un PDF, se extrae el texto (MS Extract, 5 réplicas), el cliente lo guarda
# en Persistence, lo relee y hace CRUD; por último verifica la auditoría y que
# los datos quedaron en Mongo. Comprueba que TODOS los servicios del stack
# funcionan juntos:
#   traefik-public, traefik-internal, orchestrator, extract (x5),
#   persistence, auditlog, mongo, consul.
#
# Uso:  make test-operational   (o ./tests/01-operational.sh desde deploy/)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_stack

PDF="$CORPUS_PDF"
if [[ ! -f "$PDF" ]]; then
  echo "${C_RED}ERROR${C_RESET}: no existe el PDF de prueba: $PDF" >&2
  exit 2
fi
SHA="$(sha256_of "$PDF")"

echo "PDF de prueba: $PDF"
echo "SHA-256:       $SHA"

# --- 1) Salud de todo el stack -------------------------------------------
section "1) Operatividad: contenedores y salud"
for svc in traefik-public traefik-internal orchestrator extract persistence auditlog mongo; do
  if wait_healthy "$svc" 60; then ok "servicio '$svc' healthy"; else ko "servicio '$svc' no llegó a healthy"; fi
done
if docker inspect "$CONSUL_CONTAINER" >/dev/null 2>&1; then ok "Consul '$CONSUL_CONTAINER' presente"; else ko "Consul '$CONSUL_CONTAINER' no está corriendo"; fi
n_extract="$(service_containers extract | wc -l | tr -d '[:space:]')"
assert_eq "réplicas de extract" 5 "$n_extract"

# --- 2) Borde N-S (Traefik): redirección, Host, TLS, cabeceras -----------
section "2) Borde N-S: redirección, ruteo por Host y cabeceras"
assert_status "HTTP -> HTTPS (301)"        "301" "$(raw_code http://localhost/)"
assert_status "Host desconocido (404)"     "404" "$(raw_code -k https://localhost/)"
assert_status "PDF sin Content-Type (415)" "415" "$(api_code POST /api/v1/pdfs/extract)"

hdrs="$(api_headers GET /api/v1/audit/logs?limit=1)"
assert_contains "cabecera X-Frame-Options" "SAMEORIGIN" "$hdrs"
assert_contains "cabecera X-Content-Type-Options" "nosniff" "$hdrs"

# --- 3) Extracción real (MS Extract) -------------------------------------
section "3) Extracción E2E (Traefik -> orquestador -> extract)"
api_code DELETE "/api/v1/texts/$SHA" >/dev/null || true

api_req POST /api/v1/pdfs/extract -H 'Content-Type: application/pdf' --data-binary @"$PDF"
assert_status "POST /api/v1/pdfs/extract" "200" "$RESP_CODE"

got_checksum="$(printf '%s' "$RESP_BODY" | json_field checksum)"
assert_eq "checksum == SHA-256(bytes del PDF)" "$SHA" "$got_checksum"

page_count="$(printf '%s' "$RESP_BODY" | json_field page_count)"
assert_ge "page_count >= 1" 1 "$page_count"

text_len="$(printf '%s' "$RESP_BODY" | json_field text | wc -c | tr -d '[:space:]')"
assert_ge "texto extraído no vacío (bytes)" 1 "$text_len"

# --- 4) Persistencia: guardar el texto extraído y releerlo ---------------
section "4) Persistencia (escritura/lectura) y dedup"
# Nota: el orquestador NO persiste la extracción por su cuenta; el flujo real es
# que el cliente guarde el resultado. Se arma el JSON con el texto extraído.
save_body="$(printf '%s' "$RESP_BODY" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(json.dumps({"text": d["text"], "checksum": d["checksum"], "name": "scrum-guide-prueba"}))')"
api_req POST /api/v1/texts -H 'Content-Type: application/json' --data "$save_body"
assert_status "POST /api/v1/texts (guardar extracción)" "201" "$RESP_CODE"

api_req GET "/api/v1/texts/$SHA"
assert_status "GET /api/v1/texts/{checksum}" "200" "$RESP_CODE"
assert_eq "persistence devuelve el mismo checksum" "$SHA" "$(printf '%s' "$RESP_BODY" | json_field checksum)"
stored_len="$(printf '%s' "$RESP_BODY" | json_field text | wc -c | tr -d '[:space:]')"
assert_ge "texto recuperado no vacío (bytes)" 1 "$stored_len"

# Ahora que está guardado, un nuevo extract lo sirve desde Persistence (cache).
dedup_checksum="$(api_body POST /api/v1/pdfs/extract -H 'Content-Type: application/pdf' --data-binary @"$PDF" | json_field checksum)"
assert_eq "segundo extract (cache hit) misma clave" "$SHA" "$dedup_checksum"

# --- 5) CRUD de textos (update/delete), con checksum sintético -----------
section "5) CRUD de textos (update/delete)"
FAKE="$(printf 'user-test-%s' "$(date +%s%N)" | sha256sum | awk '{print $1}')"
api_req POST /api/v1/texts -H 'Content-Type: application/json' \
  --data "{\"text\":\"hola\",\"checksum\":\"$FAKE\",\"name\":\"doc-de-prueba\"}"
assert_status "POST /api/v1/texts (create)" "201" "$RESP_CODE"

api_req PUT "/api/v1/texts/$FAKE" -H 'Content-Type: application/json' \
  --data '{"name":"doc-actualizado"}'
assert_status "PUT /api/v1/texts/{checksum} (update)" "200" "$RESP_CODE"
assert_eq "nombre actualizado" "doc-actualizado" "$(printf '%s' "$RESP_BODY" | json_field name)"

api_req DELETE "/api/v1/texts/$FAKE"
assert_status "DELETE /api/v1/texts/{checksum} (delete)" "200" "$RESP_CODE"
assert_status "GET tras delete (404)" "404" "$(api_code GET "/api/v1/texts/$FAKE")"

# --- 6) Auditoría (auditlog) ---------------------------------------------
section "6) Auditoría (auditlog)"
AUDIT_WAIT_SECONDS="${AUDIT_WAIT_SECONDS:-20}"
audit_deadline=$((SECONDS + AUDIT_WAIT_SECONDS))
found="no"
audit_error=""
while (( SECONDS <= audit_deadline )); do
  # La emisión de audit es fire-and-forget: esperar a que el evento llegue a
  # AUDA antes de concluir que falta. Filtrar por checksum evita que logs
  # históricos empujen el evento fuera de la primera página.
  api_req GET "/api/v1/audit/logs?checksum=$SHA"
  if [[ "$RESP_CODE" == "200" ]]; then
    found="$(printf '%s' "$RESP_BODY" | json_any logs checksum "$SHA")"
    [[ "$found" == "yes" ]] && break
  else
    # Un error HTTP no se puede tratar como una lista JSON ni es una demora de
    # la emisión asíncrona; conservar el body para que el fallo sea diagnosticable.
    break
  fi
  sleep 1
done
if [[ "$RESP_CODE" == "200" ]]; then
  n_logs="$(printf '%s' "$RESP_BODY" | json_field logs | json_len)"
else
  n_logs=0
  audit_error="${RESP_BODY//$'\n'/ }"
fi
assert_status "GET /api/v1/audit/logs${audit_error:+ (body: $audit_error)}" "200" "$RESP_CODE"
assert_ge "hay logs de auditoría" 1 "$n_logs"
assert_eq "existe log del extract (checksum; espera ${AUDIT_WAIT_SECONDS}s)" "yes" "$found"

# --- 7) Persistencia física en Mongo -------------------------------------
section "7) Datos en MongoDB"
texts_n="$(mongo_count pdf_extractext texts)"
audit_n="$(mongo_count pdf_extractext_audit audit_logs)"
assert_ge "colección pdf_extractext.texts con documentos" 1 "$texts_n"
assert_ge "colección pdf_extractext_audit.audit_logs con documentos" 1 "$audit_n"

summary
