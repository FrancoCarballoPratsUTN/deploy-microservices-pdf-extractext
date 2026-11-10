# Makefile de operación y pruebas del deploy.
#
# Topología: traefik-public (80/443, TLS) + traefik-internal (:8443, HTTP
# plano, sin puertos publicados), red edge + red backend (internal). Consul
# corre solo en backend (container_name: consul), sin puertos publicados.
#
# CONSUL_ENABLED es una variable de entorno del proceso fijada a "true" en los
# servicios; la configuración funcional vive en Consul KV (deploy/kv/*).
#
# Orden de arranque (`up`): NO se usa depends_on.
#   1. mongo
#   2. traefik-public, traefik-internal
#   3. extract, persistence, auditlog
#   4. kv-seed (URLs del orquestador en KV) + orchestrator
#
# Uso típico:
#   make network       # crea pdf-extractext_backend (internal) si no existe
#   make certs         # TLS de desarrollo
#   make kv-seed       # carga deploy/kv/* en Consul (requiere consul arriba)
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

-include .env

.DEFAULT_GOAL := help
.PHONY: help network check-consul certs kv-seed deploy up build down clean \
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

check-consul: ## Verifica que Consul esté corriendo solo en la red backend
	@if ! docker inspect $(CONSUL_CONTAINER) >/dev/null 2>&1; then \
	  echo "ERROR: contenedor Consul '$(CONSUL_CONTAINER)' no está corriendo" >&2; exit 1; \
	fi
	@nets="$$(docker inspect -f '{{range $$k,$$v := .NetworkSettings.Networks}}{{$$k}} {{end}}' $(CONSUL_CONTAINER))"; \
	echo "$$nets" | grep -qw "$(BACKEND_NETWORK)" || { echo "ERROR: Consul no está en $(BACKEND_NETWORK): $$nets" >&2; exit 1; }; \
	echo "$$nets" | grep -qw "mired" && { echo "ERROR: Consul sigue en mired: $$nets" >&2; exit 1; } || true; \
	ports="$$(docker inspect -f '{{json .HostConfig.PortBindings}}' $(CONSUL_CONTAINER))"; \
	case "$$ports" in ''|'{}'|'null') ;; *) echo "ERROR: Consul publica puertos: $$ports" >&2; exit 1;; esac
	@echo ">> Consul OK en $(BACKEND_NETWORK), sin puertos publicados"

kv-seed: check-consul ## Carga deploy/kv/* en Consul KV (CONSUL_ENABLED es env, no KV)
	@if [ -z "$(CONSUL_ORCHESTRATOR_TOKEN)" ]; then \
	  echo "ERROR: CONSUL_ORCHESTRATOR_TOKEN es requerido (deploy/.env)" >&2; exit 1; \
	fi
	@prefix="$${CONSUL_ORCHESTRATOR_KV_PREFIX:-pdf-extractext/dev/orchestrator}"; \
	echo ">> Seeding Consul KV ($$prefix)"; \
	while IFS='=' read -r key value || [ -n "$$key" ]; do \
	  case "$$key" in ''|\#*) continue;; esac; \
	  if ! printf '%s' "$$value" | docker exec -i \
	    -e CONSUL_HTTP_TOKEN="$(CONSUL_ORCHESTRATOR_TOKEN)" \
	    -e CONSUL_HTTP_ADDR="$(CONSUL_LOCAL_URL)" \
	    -e CONSUL_CACERT="$(CONSUL_LOCAL_CA)" \
	    $(CONSUL_CONTAINER) consul kv put "$$prefix/$$key" - >/dev/null 2>&1; then \
	    echo "ERROR: kv put $$prefix/$$key failed (403? check Consul ACL key:write)" >&2; exit 1; \
	  fi; \
	  echo "   kv put $$prefix/$$key"; \
	done < kv/orchestrator.env
	@echo ">> KV seeded"

certs: ## Genera los certificados TLS de desarrollo (mkcert)
	./certs/generate-certs.sh

up: network check-consul ## Arranque ORDENADO por fases + KV seed + espera healthy
	@echo ">> [1/5] mongo (backing store)"
	@$(COMPOSE) up -d --wait --wait-timeout $(WAIT_TIMEOUT) mongo
	@echo ">> [2/5] traefik-public, traefik-internal (borde N-S / E-W)"
	@$(COMPOSE) up -d --wait --wait-timeout $(WAIT_TIMEOUT) traefik-public traefik-internal
	@echo ">> [3/5] extract, persistence, auditlog (servicios de negocio)"
	@$(COMPOSE) up -d --wait --wait-timeout $(WAIT_TIMEOUT) extract persistence auditlog
	@echo ">> [4/5] seed KV + orchestrator (entrada)"
	@$(MAKE) --no-print-directory kv-seed
	@$(COMPOSE) up -d --force-recreate --wait --wait-timeout $(WAIT_TIMEOUT) orchestrator
	@echo ">> [5/5] Consul: reconciliando registros con los contenedores actuales"
	@./scripts/reconcile-consul-services.sh
	@echo ">> stack arriba y healthy"

deploy: build up ## Despliegue completo: build + arranque ordenado + espera healthy

build: ## Compila/actualiza las imágenes
	@cd .. && $(COMPOSE) -f deploy/compose.yaml build

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
