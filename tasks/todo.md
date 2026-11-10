# Task list: Retries in Traefik

- [x] Configure one Traefik retry for Extract and idempotent Persistence methods.
- [x] Keep circuit breakers before retries and omit retry on Audit.
- [x] Update the existing retry verifier and stub router tags.
- [x] Document `RETRY_MAX_ATTEMPTS=1` in the orchestrator Consul KV prefix.
- [x] Confirm `RETRY_MAX_ATTEMPTS=1` in the running Consul environment (already configured).
- [x] Run `make test-retry` against the deployed stack (6/6 assertions).
- [ ] Rerun the full `make test` after fixing Consul deregistration (first run: 01/02/03/05 passed; 04 failed on Consul HTTP 500; focused `make test-cb` now passes 4/4).

## Checkpoint

The migration is complete when Consul no longer enables orchestrator retries and both retry and full-stack checks pass.
