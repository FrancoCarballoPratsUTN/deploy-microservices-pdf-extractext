# Consul Specification — `pdf-extractext`

## Purpose and scope

Consul is limited to two responsibilities:

1. **Service discovery** for `orchestrator`, `extract`, `persistence`, and
   `auditlog`.
2. **Key/value configuration** loaded once during service startup.

Consul is not part of request handling, does not replace Traefik as the edge,
and does not provide logging, tracing, metrics, retries, or circuit breakers.
The application repositories remain independent from Traefik and Consul
topology.

## Topology and network boundaries

- Two Traefik instances split responsibilities:
  - `traefik-public` (edge + backend): only public edge, publishes `80/443`,
    terminates TLS, discovers services tagged `gateway-public`.
  - `traefik-internal` (backend only): internal E-W gateway on `:8443` over
    plain HTTP, no published ports, discovers services tagged
    `gateway-internal`. Retries apply only here; the public face to the
    orchestrator is never retried.
- Two Docker data networks:
  - `edge`: project network used by `traefik-public`.
  - `backend`: external, `internal: true`, name `pdf-extractext_backend`.
    `traefik-public`, `traefik-internal`, `orchestrator`, `extract`,
    `persistence`, `auditlog`, `mongo`, and Consul share it. No TLS inside.
- Consul runs from `/home/francocp12/Documents/Services/consul` on `backend`
  only (`container_name: consul`). It does not join `mired`. Its UI/API is
  published **only on loopback** (`127.0.0.1:8501`); it is never bound to
  `0.0.0.0` or exposed through Traefik. Host access for tests/scripts/bootstrap
  uses `docker exec`. Consul remains outside the request path.

## Service discovery contract

Each service registers itself at startup and deregisters during graceful
shutdown:

| Service | Consul name | Health check |
|---|---|---|
| Orchestrator | `orchestrator` | `GET /readyz` |
| Extractor | `extract` | `GET /healthz` |
| Persistence | `persistence` | `GET /readyz` |
| Audit log | `auditlog` | `GET /readyz` |

Registration metadata must include the address, application port, protocol,
environment, and the Traefik tags required for routing. Health checks must
fail when the service cannot accept traffic. Deregistration must be attempted
before the process exits and must not delay shutdown beyond the configured
shutdown deadline.

A successful `/v1/agent/service/deregister` response proves local agent removal,
not catalog removal. The Consul agent must also propagate service/check removal
to the catalog used by Traefik. All four application checks run every 10 seconds
and set `DeregisterCriticalServiceAfter: "1m"`; after a crash or an unresponsive
instance, Consul may take slightly longer than that minute because its critical
service reaper runs periodically. This fallback does not replace graceful
deregistration.

## Traefik integration

Both Traefik instances use the `consulCatalog` provider with a read-only Consul
token and provider-level constraints:

- `traefik-public`: `constraints: 'Tag(`gateway-public`)'`
- `traefik-internal`: `constraints: 'Tag(`gateway-internal`)'`

Routers and services are declared as Consul tags (no Docker labels for business
routing). The orchestrator is tagged `gateway-public`; E-W services are tagged
`gateway-internal`. The file provider remains the source of reusable policy:

- `tls.yml` (mounted only by `traefik-public`): TLS certificates.
- `dynamic.yml` (mounted by both): security/rate-limit middlewares,
  `serversTransport`, and independent circuit breakers/retries per backend.

Circuit breaker state is not shared between services. A failure in Persistence
must not open the Extract circuit. Health aggregation uses direct DNS between
the orchestrator and microservices on `backend`; no public health routers are
exposed. Docker labels must not define business routers, services, middlewares,
or load-balancer policy.

## KV contract

Keys use this layout:

```text
pdf-extractext/<environment>/<service>/<VARIABLE>
```

Values are strings and are parsed and validated by the service's existing
configuration boundary. Required deployment values fail startup when absent or
invalid. Consul is read at startup only; no request performs a KV lookup.
Compose keeps only bootstrap connectivity (address, CA path and ACL tokens);
functional application configuration is stored under each service KV prefix.

`CONSUL_ENABLED` is a **process environment variable** (not a KV key). Deploy
fixes it to `"true"` in `compose.yaml` for every service. Per-microservice
`.env` files may keep `CONSUL_ENABLED=false` for standalone testing.

`make kv-seed` writes `deploy/kv/orchestrator.env` via `docker exec` using
`CONSUL_ORCHESTRATOR_TOKEN`. It seeds the orchestrator E-W/health URLs and
`RETRY_MAX_ATTEMPTS=1` (Traefik owns E-W retries):

```bash
cd deploy && make kv-seed
docker compose up -d --force-recreate orchestrator
```

The local-development mode may use process environment variables or a local
`.env` only when explicitly enabled. Deployment mode uses Consul KV and does
not silently fall back to an incomplete local configuration.

## Security requirements

- Consul must use HTTPS with a CA trusted by its clients.
- ACL policy must be `deny` by default.
- Traefik receives a read-only catalog token.
- Each application receives only the KV read and service registration
  permissions it needs.
- The Consul agent has a dedicated internal token with `node:write` only for its
  own node and service read permission required by anti-entropy. It is installed
  through the agent-token API and persisted with `acl.enable_token_persistence`;
  application and anonymous tokens do not receive broader rights.
- Management and bootstrap tokens must be injected from outside Git. Management
  credentials are used only by the idempotent ACL bootstrap, never as the agent's
  runtime token or printed by operational scripts.
- The Consul server certificate includes the `server.<datacenter>.consul` SAN
  required by verified internal RPC TLS. Certificate renewal preserves the CA
  trusted by applications; hostname verification remains enabled.
- Certificates, private keys, and tokens must not appear in compose files,
  `.env.example`, Consul tags, or versioned documentation.
- Consul's management API must not be published through the application edge.
  Host exposure is restricted to loopback (`127.0.0.1:8501`) and must never bind
  to a routable interface (`0.0.0.0`, `::`, LAN IP).

## Bootstrap and operations

Bootstrap must be idempotent and must separate non-secret defaults from secret
material. From `deploy/`:

```bash
make network       # crea pdf-extractext_backend (internal) si no existe
# recrear/levantar Consul desde /home/francocp12/Documents/Services/consul
make certs
make kv-seed       # escribe deploy/kv/* en Consul KV vía docker exec
make deploy
make test
```

The Makefile provides explicit steps for: network creation, Consul access check,
KV seeding, ordered startup, reconciliation, and tests. `make up` seeds KV and
recreates the orchestrator so it does not start with stale KV URLs.

For the external single-node Consul used by this deployment, bootstrap or repair
its internal agent ACL and renew its server certificate from
`/home/francocp12/Documents/Services/consul` (both scripts use `docker exec`):

```bash
./scripts/bootstrap-agent-acl.sh
./scripts/renew-server-cert.sh
docker compose restart consul
```

The deployment must fail clearly when Consul is unavailable, the token is
invalid, a certificate cannot be verified, or a required KV key is missing.
After restart, `make test-consul-lifecycle` verifies real graceful and critical
cleanup from `deploy/` without direct catalog writes.

## Acceptance criteria

- All four services register, pass their checks, deregister on shutdown from both
  agent and catalog, and are purged after the configured critical interval.
- Traefik discovers application backends through `consulCatalog`.
- No business routing depends on Docker labels.
- Required runtime configuration comes from the documented KV prefix.
- Consul is used only for discovery and KV.
- Existing `edge`/`backend` separation and independent circuit breakers remain
  intact.
- The local development mode and deployment mode are explicitly distinct.
