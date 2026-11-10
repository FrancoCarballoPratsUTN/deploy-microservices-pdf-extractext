#!/usr/bin/env bash
#
# Test de salud del orquestador:
# - /healthz debe responder 200 (liveness)
# - /readyz debe responder 200 cuando dependencias están saludables (readiness agregado)
set -euo pipefail

cd "$(dirname "$0")/.."

check_internal() {
  local path="$1"
  docker compose exec -T orchestrator wget -qO- "http://127.0.0.1:8080${path}" | grep -q '"status":"ok"' && \
    echo "  ok   orchestrator:${path} → 200 con status ok" || {
      echo "  FAIL orchestrator:${path}" >&2
      exit 1
    }
}

echo "== Health checks internos (orquestador) =="
check_internal /healthz
check_internal /readyz
echo "== OK =="

