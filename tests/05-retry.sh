#!/usr/bin/env bash
#
# Test de los middlewares *retry* del tramo E-W.
#
# Delega en scripts/verify-retries.sh, que ejercita de forma determinista:
#   - extract-retry: POST /extract reintenta una respuesta 502
#   - persistence-retry: GET /texts reintenta y POST /texts no se reintenta
#
# Uso:  make test-retry   (o ./tests/05-retry.sh desde deploy/)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_stack

section "Retry (extract-retry + persistence-retry)"
if "$DEPLOY_DIR/scripts/verify-retries.sh"; then
  ok "verify-retries.sh: 6/6 aserciones"
else
  ko "verify-retries.sh falló"
fi

summary
