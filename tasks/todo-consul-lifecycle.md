# Task list: Consul service lifecycle

## Task 1: Reproduce the lifecycle defect with a deployment test

**Description:** Add an integration test that stops and restarts the orchestrator, then pauses it until its existing Consul check becomes critical and the one-minute reaper should remove it. The test performs reads against Consul but never repairs the catalog itself, and it always restores the orchestrator.

**Acceptance criteria:**
- [x] A new test checks graceful agent/catalog removal, Traefik convergence, re-registration, and critical-service removal after `DeregisterCriticalServiceAfter`.
- [x] The test is included in `make test` and has a focused Make target; its EXIT trap restores a healthy orchestrator.
- [x] RED recorded against the unfixed agent: 9 assertions passed and 2 failed because `orchestrator-e1c7fe3fa121` remained after both graceful stop and the critical timeout.

**Verification:**
- [x] `bash -n tests/06-consul-lifecycle.sh` passes.
- [x] `make test-consul-lifecycle` fails on the unfixed configuration for the expected stale catalog state (9 ok, 2 failed).
- [x] After RED, `docker compose ps orchestrator` reports a running healthy container.

**Dependencies:** None.

**Files likely touched:**
- `tests/06-consul-lifecycle.sh`
- `tests/run-all.sh`
- `Makefile`

**Estimated scope:** Medium: 3 files.

## Task 2: Bootstrap the Consul agent ACL token

**Description:** Add an idempotent bootstrap utility in the external Consul deployment that creates/updates the minimum agent policy, creates or reuses its token, and installs it as the agent token through Consul's authenticated API without logging secret material.

**Acceptance criteria:**
- [x] Policy grants `node:write` only to `ds` and `service_prefix ""` read; no application policy or anonymous-token policy is weakened.
- [x] Re-running bootstrap preserves one logical policy/token and the agent token survives restart through the existing token-persistence setting (verified by the post-restart lifecycle run).
- [x] Graceful lifecycle checks turn GREEN without any direct `/v1/catalog/deregister` call from the test.

**Verification:**
- [x] Shell static check passes for the bootstrap utility.
- [x] Bootstrap succeeds twice with no token value printed.
- [x] The focused lifecycle test passes all 11 assertions and Consul logs no new anonymous deregistration ACL warning.

**Dependencies:** Task 1.

**Files likely touched:**
- `/home/francocp12/Documents/Services/consul/config/agent-policy.hcl`
- `/home/francocp12/Documents/Services/consul/scripts/bootstrap-agent-acl.sh`
- `/home/francocp12/Documents/Services/consul/README.md` (operational usage only)

**Estimated scope:** Medium: 3 files.

## Task 3: Add the internal RPC hostname to the Consul certificate

**Description:** Add a reproducible certificate-renewal utility that preserves the current CA and server key, adds `server.dc-converter.consul` alongside the existing SANs, verifies the resulting certificate, and recreates Consul once to load ACL/TLS changes.

**Acceptance criteria:**
- [x] The renewed certificate chains to the existing CA and contains `consul`, `localhost`, `127.0.0.1`, and `server.dc-converter.consul`.
- [x] `verify_outgoing` and `verify_server_hostname` remain enabled.
- [x] Consul starts successfully and no new internal RPC log reports the old hostname mismatch.

**Verification:**
- [x] Shell static check and `openssl verify` pass; CA and server private key hashes were unchanged.
- [x] `openssl x509 -checkhost server.dc-converter.consul` succeeds.
- [x] The focused lifecycle test is GREEN (11/11) after Consul restart and application discovery convergence.

**Dependencies:** Task 2 (one coordinated live restart after ACL bootstrap).

**Files likely touched:**
- `/home/francocp12/Documents/Services/consul/scripts/renew-server-cert.sh`
- `/home/francocp12/Documents/Services/consul/config/tls/consul-server.pem` (generated, gitignored)
- `/home/francocp12/Documents/Services/consul/README.md` (renewal command)

**Estimated scope:** Small: 2 source files plus one generated certificate.

## Checkpoint: After Tasks 1-3

- [x] `make test-consul-lifecycle` passes graceful and critical cleanup (11/11 before and after Consul restart).
- [x] No manual catalog deregistration was used by the lifecycle test.
- [x] Consul ACL/TLS errors are absent from fresh logs and the stack is healthy.

## Task 4: Document lifecycle operations and outage semantics

**Description:** Update the external Consul README and deployment Consul documentation with repeatable ACL/TLS bootstrap steps, the difference between agent and catalog state, automatic cleanup timing, and what users experience while the single orchestrator is down.

**Acceptance criteria:**
- [x] Operators can reproduce ACL bootstrap and certificate renewal without embedding real tokens or keys in documentation.
- [x] Documentation states that the one-minute critical reaper can take slightly longer and does not replace graceful deregistration.
- [x] Documentation distinguishes healthy internal microservices from public API availability during an orchestrator outage.

**Verification:**
- [x] Documented commands match the implemented script paths and Make targets (`make help` and path checks).
- [x] `CONSUL-SPEC.md` and deployment troubleshooting explicitly distinguish local agent deregistration from catalog cleanup.

**Dependencies:** Tasks 2 and 3.

**Files likely touched:**
- `/home/francocp12/Documents/Services/consul/README.md`
- `CONSUL-SPEC.md`
- `README.md`

**Estimated scope:** Medium: 3 files.

## Task 5: Verify everything and close the retry checkpoint

**Description:** Run the focused and complete deployment suites after the Consul fix, verify final live registrations, and mark both this plan and the pre-existing retry plan complete only if every check passes.

**Acceptance criteria:**
- [ ] The new lifecycle test and all previous deployment suites pass without skipped assertions.
- [ ] `tasks/plan.md` and `tasks/todo.md` record the now-successful full-suite checkpoint.
- [ ] Final Consul/Compose state contains only registrations for current running application instances.

**Verification:**
- [ ] `make test` passes, including `04-circuit-breaker.sh` and `06-consul-lifecycle.sh`.
- [ ] `docker compose ps` shows all expected services healthy.
- [ ] Consul catalog IDs and agent IDs match current Compose hostnames; no stale orchestrator instance remains.

**Dependencies:** Tasks 1-4 and the blocked checkpoint in `tasks/plan.md`.

**Files likely touched:**
- `tasks/plan-consul-lifecycle.md`
- `tasks/todo-consul-lifecycle.md`
- `tasks/plan.md`
- `tasks/todo.md`

**Estimated scope:** Small: 4 tracking files; no production-code changes expected.

## Checkpoint: Complete

- [ ] All acceptance criteria are met and the stack is restored.
- [ ] No real token, private key, or certificate private material appears in task files or test output.
- [ ] Human review can compare the RED result from Task 1 with the GREEN focused and full-suite results.
