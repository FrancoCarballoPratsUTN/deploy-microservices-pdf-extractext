# Makefile de operación y pruebas del deploy.
#
# Topología: traefik-public (80/443, TLS) + traefik-internal (:8443, HTTP
# plano, sin puertos publicados), red edge + red backend (internal). Consul
# corre solo en backend (container_name: consul); su UI/API se publica
# únicamente en loopback (127.0.0.1:8501), nunca en la red.
#
# CONSUL_ENABLED es una variable de entorno del proceso fijada a "true" en los
# servicios; la configuración funcional vive en Consul KV (deploy/kv/*).
#
# Orden de arranque (`up`): NO se usa depends_on.
#   1. mongo
#   2. traefik-public, traefik-internal
#   3. kv-seed (4 prefijos) + extract, persistence, auditlog
#   4. espera a que Consul los reporte `passing` (enrutables por Traefik)
#   5. orchestrator (relee KV)
#   6. reconciliación de registros obsoletos en Consul
#
# Uso típico:
#   make network       # crea pdf-extractext_backend (internal) si no existe
#   make certs         # TLS de desarrollo
#   make kv-seed       # siembra deploy/kv/*.env en Consul (requiere consul arriba)
#   make deploy        # build + arranque ordenado + reconciliación
#   make test          # corre toda la batería
#
SHELL := /bin/bash
COMPOSE ?= docker compose
TESTS_DIR := tests
WAIT_TIMEOUT ?= 180
BACKEND_NETWORK ?= pdf-extractext_backend
CONSUL_CONTAINER ?= consul
CONSUL_LOCAL_CA ?= /consul/config/tls/consul-ca.pem
CONSUL_LOCAL_URL ?= https://127.0.0.1:8501
# Servicios que deben estar `passing` en Consul antes de arrancar el orquestador.
CONSUL_WAIT_SERVICES ?= extract persistence auditlog

-include .env

.DEFAULT_GOAL := help
.PHONY: help network check-consul consul-ui wait-consul certs kv-seed deploy up build down clean \
        restart ps logs urls \
        test test-operational test-network test-ratelimit test-cb test-retry \
        test-consul-lifecycle test-health

help: ## Muestra esta ayuda
	@echo "Deploy pdf-extractext - targets disponibles:"
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

network: ## Crea la red privada backend (internal) si no existe
	@if docker network inspect $(BACKEND_NETWORK) >/dev/null 2>&1; then \
	  internal="$$(docker network inspect $(BACKEND_NETWORK) --format '{{.Internal}}')"; \
	  if [ "$$internal" != "true" ]; then \
	    echo "ERROR: $(BACKEND_NETWORK) existe pero no es internal=true" >&2; exit 1; \
	  fi; \
	  echo ">> red $(BACKEND_NETWORK) ya existe (internal=true)"; \
	else \
	  docker network create --driver bridge --internal $(BACKEND_NETWORK); \
	  echo ">> red $(BACKEND_NETWORK) creada (internal=true)"; \
	fi

check-consul: ## Verifica Consul en backend y su UI/API sólo en loopback:8501
	@if ! docker inspect $(CONSUL_CONTAINER) >/dev/null 2>&1; then \
	  echo "ERROR: contenedor Consul '$(CONSUL_CONTAINER)' no está corriendo" >&2; exit 1; \
	fi
	@nets="$$(docker inspect -f '{{range $$k,$$v := .NetworkSettings.Networks}}{{$$k}} {{end}}' $(CONSUL_CONTAINER))"; \
	echo "$$nets" | grep -qw "$(BACKEND_NETWORK)" || { echo "ERROR: Consul no está en $(BACKEND_NETWORK): $$nets" >&2; exit 1; }; \
	echo "$$nets" | grep -qw "mired" && { echo "ERROR: Consul sigue en mired: $$nets" >&2; exit 1; } || true
	@docker inspect -f '{{json .HostConfig.PortBindings}}' $(CONSUL_CONTAINER) | python3 -c 'import json,sys; d=json.load(sys.stdin) or {}; allowed=lambda p,ip,hp: p=="8501/tcp" and hp=="8501" and ip in ("127.0.0.1","::1"); bad=["%s->%s:%s" % (p, b.get("HostIp",""), b.get("HostPort","")) for p, bs in d.items() for b in (bs or []) if not allowed(p, b.get("HostIp",""), b.get("HostPort",""))]; sys.stderr.write("ERROR: Consul publica puertos no permitidos: " + ", ".join(bad) + " (sólo 127.0.0.1:8501)\n") if bad else None; sys.exit(1 if bad else 0)'
	@echo ">> Consul OK en $(BACKEND_NETWORK); UI/API sólo en https://127.0.0.1:8501"

consul-ui: ## Muestra la URL y el CA para entrar a la UI de Consul
	@echo "UI Consul: $(CONSUL_LOCAL_URL)/ui"
	@echo "  CA a confiar en el navegador: $(CONSUL_CA_FILE)"
	@echo "  Login con el management token (CONSUL_INITIAL_MANAGEMENT_TOKEN)."

wait-consul: ## Espera a que los servicios estén `passing` en Consul
	@WAIT_TIMEOUT=$(WAIT_TIMEOUT) ./scripts/wait-consul-passing.sh $(CONSUL_WAIT_SERVICES)

kv-seed: check-consul ## Carga deploy/kv/*.env en Consul KV (un prefijo por servicio)
	@if [ -z "$(CONSUL_KV_SEED_TOKEN)" ]; then \
	  echo "ERROR: CONSUL_KV_SEED_TOKEN es requerido (token con key:write bajo el prefijo raíz)" >&2; exit 1; \
	fi
	@set -euo pipefail; \
	seed() { \
	  local service="$$1" prefix="$$2" file="kv/$$1.env" key value; \
	  if [ ! -f "$$file" ]; then \
	    echo "ERROR: falta $$file" >&2; return 1; \
	  fi; \
	  echo ">> Seeding $$prefix ($$file)"; \
	  while IFS='=' read -r key value || [ -n "$$key" ]; do \
	    case "$$key" in ''|\#*) continue;; esac; \
	    if ! printf '%s' "$$value" | docker exec -i \
	      -e CONSUL_HTTP_TOKEN="$(CONSUL_KV_SEED_TOKEN)" \
	      -e CONSUL_HTTP_ADDR="$(CONSUL_LOCAL_URL)" \
	      -e CONSUL_CACERT="$(CONSUL_LOCAL_CA)" \
	      $(CONSUL_CONTAINER) consul kv put "$$prefix/$$key" - >/dev/null 2>&1; then \
	      echo "ERROR: kv put $$prefix/$$key failed (403? falta key:write en el token de seed)" >&2; return 1; \
	    fi; \
	    echo "   kv put $$prefix/$$key"; \
	  done < "$$file"; \
	}; \
	seed orchestrator "$(or $(CONSUL_ORCHESTRATOR_KV_PREFIX),pdf-extractext/dev/orchestrator)"; \
	seed extract      "$(or $(CONSUL_EXTRACT_KV_PREFIX),pdf-extractext/dev/extract)"; \
	seed persistence  "$(or $(CONSUL_PERSISTENCE_KV_PREFIX),pdf-extractext/dev/persistence)"; \
	seed auditlog     "$(or $(CONSUL_AUDIT_KV_PREFIX),pdf-extractext/dev/auditlog)"
	@echo ">> KV seeded: 4 prefijos"

certs: ## Genera los certificados TLS de desarrollo (mkcert)
	./certs/generate-certs.sh

up: network check-consul ## Arranque ORDENADO por fases + KV seed + espera healthy
	@echo ">> [1/6] mongo (backing store)"
	@$(COMPOSE) up -d --wait --wait-timeout $(WAIT_TIMEOUT) mongo
	@echo ">> [2/6] traefik-public, traefik-internal (borde N-S / E-W)"
	@$(COMPOSE) up -d --wait --wait-timeout $(WAIT_TIMEOUT) traefik-public traefik-internal
	@echo ">> [3/6] seed KV (4 prefijos) + extract, persistence, auditlog"
	@$(MAKE) --no-print-directory kv-seed
	@$(COMPOSE) up -d --wait --wait-timeout $(WAIT_TIMEOUT) extract persistence auditlog
	@echo ">> [4/6] Consul: esperando a que los servicios de negocio estén passing"
	@WAIT_TIMEOUT=$(WAIT_TIMEOUT) ./scripts/wait-consul-passing.sh $(CONSUL_WAIT_SERVICES)
	@echo ">> [5/6] orchestrator (entrada; relee KV con --force-recreate)"
	@$(COMPOSE) up -d --force-recreate --wait --wait-timeout $(WAIT_TIMEOUT) orchestrator
	@echo ">> [6/6] Consul: reconciliando registros con los contenedores actuales"
	@./scripts/reconcile-consul-services.sh
	@echo ">> stack arriba y healthy"

deploy: build up ## Despliegue completo: build + arranque ordenado + espera healthy

build: ## Compila/actualiza las imágenes
	@cd .. && $(COMPOSE) -f deploy-microservices-pdf-extractext/compose.yaml build

down: ## Baja el stack (conserva volúmenes/datos)
	$(COMPOSE) down

clean: ## Baja el stack y BORRA volúmenes (mongo) y huérfanos
	$(COMPOSE) down -v --remove-orphans

restart: ## Reinicia todos los servicios
	$(COMPOSE) restart

ps: ## Estado de los contenedores
	$(COMPOSE) ps

logs: ## Sigue los logs de todos los servicios
	$(COMPOSE) logs -f --tail=100

urls: ## Muestra las URLs públicas del borde
	@echo "N-S (público, traefik-public):  https://pdf-extractext.localhost/api"
	@echo "  extract:  POST https://pdf-extractext.localhost/api/v1/pdfs/extract"
	@echo "  texts:    GET  https://pdf-extractext.localhost/api/v1/texts/{checksum}"
	@echo "  audit:    GET  https://pdf-extractext.localhost/api/v1/audit/logs"
	@echo "  (curl --cacert certs/rootCA.pem --resolve pdf-extractext.localhost:443:127.0.0.1 ...)"

# ----------------------------------------------------------------------- tests
test: up ## Corre TODA la batería de tests de usuario
	./$(TESTS_DIR)/run-all.sh

test-operational: up ## Test de operatividad E2E de todos los servicios
	./$(TESTS_DIR)/01-operational.sh

test-network: up ## Test de aislamiento de red y endurecimiento
	./$(TESTS_DIR)/02-network.sh

test-ratelimit: up ## Test del rate limit del borde (429)
	./$(TESTS_DIR)/03-rate-limit.sh

test-cb: up ## Test del circuit breaker E-W (503 + recuperación)
	./$(TESTS_DIR)/04-circuit-breaker.sh

test-retry: up ## Test de los middlewares de retry E-W
	./$(TESTS_DIR)/05-retry.sh

test-consul-lifecycle: up ## Verifica baja graceful y purga crítica en Consul
	./$(TESTS_DIR)/06-consul-lifecycle.sh

test-health: ## Health checks internos del orquestador
	@set -e; \
	printf ">> health checks...\n"; \
	./tests/health.sh
	@printf "\n>> TEST HEALTH: OK\n"
