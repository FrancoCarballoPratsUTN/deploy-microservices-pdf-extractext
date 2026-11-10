#!/usr/bin/env bash
#
# Corre toda la batería de tests de usuario del deploy.
#
#   01-operational    operatividad E2E (todos los servicios + Consul)
#   02-network        dos redes, dos Traefik, Consul privado, endurecimiento
#   03-rate-limit     rate limit del borde público (429)
#   04-circuit-breaker circuit breaker E-W en traefik-internal (503 y recuperación)
#   05-retry          middlewares de reintento E-W en traefik-internal
#   06-consul-lifecycle baja graceful y purga de instancias críticas
#
# Uso:  make test   (o ./tests/run-all.sh desde deploy/)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

TESTS=(01-operational.sh 02-network.sh 03-rate-limit.sh 04-circuit-breaker.sh 05-retry.sh 06-consul-lifecycle.sh)
declare -A RESULT
fail=0

for t in "${TESTS[@]}"; do
  echo
  echo "############################## $t ##############################"
  if bash "$t"; then
    RESULT["$t"]="ok"
  else
    RESULT["$t"]="FALLÓ"
    fail=1
  fi
done

echo
echo "============================== RESUMEN =============================="
for t in "${TESTS[@]}"; do
  printf '  %-26s %s\n' "$t" "${RESULT[$t]}"
done
echo "===================================================================="
if (( fail == 0 )); then
  echo "TODOS LOS TESTS OK"
else
  echo "HAY TESTS FALLIDOS"
fi
exit $fail
