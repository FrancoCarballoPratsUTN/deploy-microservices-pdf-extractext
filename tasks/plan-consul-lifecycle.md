# Implementation Plan: Consul service lifecycle

## Overview

Fix the confirmed split between Consul's local agent state and its catalog: services deregister locally during graceful shutdown, but the agent's anonymous internal token cannot propagate service/check removal to the catalog. Add a regression test that exercises both graceful deregistration and the existing critical-service reaper without manual catalog cleanup, repair the Consul agent ACL and internal TLS hostname, then rerun the complete deployment suite and close the blocked retry plan.

Tasks are tracked in `tasks/todo-consul-lifecycle.md`; the pre-existing retry plan remains in `tasks/plan.md` and `tasks/todo.md` until its full-suite checkpoint passes.

## Architecture Decisions

- Configure a dedicated Consul **agent token** for internal anti-entropy operations. Do not use the management token for runtime work and do not broaden application tokens.
- Use the documented minimum agent policy: `node:write` only for node `ds`, plus `service_prefix ""` read so the agent can diff local and catalog state. Node write permits service/check deregistration on that node.
- Bootstrap the policy/token idempotently through the management API, then set `acl.tokens.agent` through Consul's agent-token API. The existing `acl.enable_token_persistence: true` persists it across agent restarts; token secrets must not be written to Git or printed.
- Keep the existing Consul CA and server private key. Renew only the server certificate with the additional SAN `server.dc-converter.consul`; do not disable `verify_server_hostname`.
- Keep the existing application registrations unchanged: all four services already send `DeregisterCriticalServiceAfter: "1m"` with 10-second HTTP checks.
- The new lifecycle test must never call `/v1/catalog/deregister` or the reconciliation script to make itself pass. It must restore the orchestrator on every exit.
- Orchestrator high availability and public routing that bypasses it are out of scope. With one orchestrator, its outage still makes the public API unavailable while internal services remain healthy.

## Dependency Graph

```text
Lifecycle regression test (RED)
    │
    ├── Agent ACL bootstrap ──► graceful and critical catalog cleanup (GREEN)
    │                                │
    └── TLS SAN renewal ─────────────┴──► clean Consul internal operation
                                           │
                                           ├── Operational documentation
                                           └── Full make test ──► close retry checkpoint
```

## Task List

### Phase 1: Reproduction and control-plane repair
- [x] Task 1: Add a real Consul lifecycle regression test and observe it fail without manual cleanup (RED: 9 ok, 2 failed).
- [x] Task 2: Bootstrap and persist a least-privilege Consul agent token (idempotent bootstrap ran twice; lifecycle GREEN 11/11).
- [x] Task 3: Renew the Consul server certificate with the internal RPC SAN (CA/key preserved; restart and lifecycle GREEN 11/11).

### Checkpoint: Consul lifecycle green
- [x] The lifecycle test passes graceful and critical cleanup without direct catalog deregistration.
- [x] Consul no longer logs anonymous ACL deregistration failures or the `server.dc-converter.consul` certificate mismatch.
- [x] Traefik no longer routes to the stopped orchestrator registration.

### Phase 2: Operations and full verification
- [x] Task 4: Document ACL bootstrap, TLS renewal, lifecycle behavior, and the single-orchestrator outage boundary.
- [ ] Task 5: Run all service/deployment checks and close the pre-existing retry checkpoint.

### Checkpoint: Complete
- [ ] `make test` passes, including the new lifecycle test and the previously failing circuit-breaker suite.
- [ ] All services are restored and healthy; Consul registrations match running containers.
- [ ] No token or private key content is added to tracked documentation, plans, tests, or command output.

## Risks and Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Agent token has excessive privileges | Compromise could alter unrelated catalog state | Limit node write to `ds`; grant service read only as required for anti-entropy; keep secrets out of logs and Git. |
| Consul restart interrupts discovery updates | Temporary stale routing while the control plane is down | Use the existing development single-node deployment, restart once after ACL/TLS changes, and verify Traefik convergence afterward. |
| Replacing the CA breaks every client | All application registration/KV traffic fails TLS validation | Reuse the current CA and server key; replace only the server certificate and verify its chain and SANs before restart. |
| Lifecycle test leaves the public API down | Subsequent tests and user requests fail | Use an EXIT trap that unpauses and restarts the orchestrator, waits for health, and checks registration. |
| Existing tests conceal the bug with manual cleanup | False GREEN while production still leaves stale registrations | Keep manual cleanup only in legacy fixtures that need deterministic stubs; the new lifecycle test performs no catalog writes. |

## Open Questions

- None for this bug fix. Orchestrator replication is intentionally deferred as a separate availability decision.
