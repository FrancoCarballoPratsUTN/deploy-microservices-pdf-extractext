# Implementation Plan: Retries in Traefik

## Overview

Move transient retries for E-W requests from the orchestrator to Traefik, keeping the policy small and avoiding duplicated writes. Traefik will retry one time on 502–504; Extract may replay its PDF POST, while Persistence will only retry idempotent methods. Audit remains without gateway retries.

## Decisions

- Keep the circuit breaker before the retry middleware in each router chain, so an open breaker short-circuits without retrying.
- Use one Traefik retry (`attempts: 1`) for 502–504, with short exponential backoff.
- Allow replay of Extract's POST; the request body limit is 16 MiB for PDFs up to 15 MiB.
- Leave `retryNonIdempotentMethod` disabled for Persistence. Duplicate checksum protection prevents a duplicate row, but the current API returns 409 rather than replaying the original success.
- Set orchestrator `RETRY_MAX_ATTEMPTS=1` in Consul KV. The deploy configuration loads functional settings from Consul KV, so the Compose environment fallback alone does not disable its retry loop.

## Task List

### Phase 1: Gateway policy
- [x] Add the Extract and Persistence retry middlewares.
- [x] Attach them after the circuit breakers through Consul service tags.
- [x] Keep test stubs' router tags aligned with production.

### Phase 2: Verify behavior and document operations
- [x] Replace the stale retry verifier with checks for Extract retry, Persistence GET retry, and no Persistence POST retry.
- [x] Document the Consul KV setting needed to disable orchestrator retries.
- [x] Confirm the retry verifier (the running Consul KV value was already `RETRY_MAX_ATTEMPTS=1`; `make test-retry` passed 6/6 assertions).

### Checkpoint: Migration ready
- [x] Orchestrator Consul KV has `RETRY_MAX_ATTEMPTS=1` under its configured prefix.
- [x] `make test-retry` passes and restores services (6/6 assertions).
- [ ] Full `make test` passes.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Orchestrator still retries from Consul KV | Nested retries multiply upstream calls | Set the KV value to `1` before recreating the orchestrator. |
| Retrying `POST /texts` after a committed write | Client receives 409 on replay | Keep POST excluded until duplicate requests return the prior success. |
| PDF exceeds Traefik's replay buffer | Extract retry cannot replay the request | Set `maxRequestBodyBytes` to 16 MiB for the 15 MiB PDF limit. |

## Verification

- Static review of Compose tags, middleware names, and Consul KV instructions.
- `make test-retry`: passed (6/6 assertions).
- First `make test`: blocked by the Consul deregistration defect in `04-circuit-breaker.sh` (catalog deregistration returned HTTP 500). Suites 01, 02, 03 and 05 passed.
- Consul prerequisite: after the agent ACL/TLS fix, focused `make test-cb` passes (4/4 assertions: 502 → 503 → recovery 200). The full `make test` checkpoint remains open for its final rerun.
