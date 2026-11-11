# `deploy/` — Despliegue unificado (dos Traefik, Consul privado)

Despliegue **unificado** del sistema *pdf-extractext*: un único `compose.yaml`
levanta `traefik-public` + `traefik-internal` + orquestador + extract (×5) +
persistence + auditlog + Mongo. Consul corre aparte, **solo en la red privada**;
su UI/API se publica únicamente en loopback (`127.0.0.1:8501`).

- **Borde público**: `traefik-public` (80/443, TLS). Único servicio que publica puertos en la red; en loopback quedan Consul (`127.0.0.1:8501`) y mongo (`127.0.0.1:27017`, para Compass).
- **Gateway E-W**: `traefik-internal` (`:8443`, HTTP plano, sin puertos). Los retries E-W viven aquí; la cara pública nunca se reintenta.
- **Redes**: `edge` (proyecto) y `backend` (externa, `internal: true`, `pdf-extractext_backend`). `backend` la comparten Traefik público/interno, orquestador, MS, mongo y Consul. Sin TLS interno. `mongo-local`: puente no interno que sólo usa mongo para publicar `27017` en loopback.
- **Consul**: `container_name: consul`, solo en `backend`, sin `mired`. Host/tests/scripts acceden por `docker exec`; la UI/API se expone sólo en `127.0.0.1:8501` (`https://localhost:8501/ui`).
- **`CONSUL_ENABLED`**: variable de **entorno del proceso**, fijada a `"true"` en `compose.yaml`. No es clave de KV ni se lee de `deploy/.env`. La config funcional vive en Consul KV (`deploy/kv/*`, `make kv-seed`).

> Nota: este README conserva contexto histórico de fases anteriores; las secciones operativas críticas (bootstrap, redes, Traefik, Consul, tests) reflejan la topología actual. Si algo contradice el compose/Makefile, manda el compose/Makefile.

---

## Índice

1. [Objetivo y alcance](#1-objetivo-y-alcance)
2. [Arquitectura](#2-arquitectura)
3. [Estructura de archivos](#3-estructura-de-archivos)
4. [Decisiones de diseño (y por qué)](#4-decisiones-de-diseño-y-por-qué)
5. [Requisitos](#5-requisitos)
6. [Puesta en marcha paso a paso](#6-puesta-en-marcha-paso-a-paso)
7. [Verificación paso a paso](#7-verificación-paso-a-paso)
8. [Comportamiento del borde (medido)](#8-comportamiento-del-borde-medido)
9. [Fase 12: resiliencia del orquestador](#9-fase-12-resiliencia-del-orquestador)
10. [Endurecimiento](#10-endurecimiento)
11. [Limitaciones conocidas y desvíos](#11-limitaciones-conocidas-y-desvíos)
12. [Solución de problemas](#12-solución-de-problemas)
13. [Referencias](#13-referencias)

---

## 1. Objetivo y alcance

Antes de la Fase 11 el **orquestador** era el punto público único y hablaba
directo con los microservicios por sus puertos. Esta fase introduce un
**Traefik propio** que:

- es el **gateway N-S** (norte-sur): el único servicio que publica puertos en
  las interfaces de red del host (`80`/`443`) y termina TLS; mongo y Consul
  sólo publican en loopback;
- es el **router E-W** (este-oeste): todo el tráfico entre el orquestador y los
  MS pasa por su entrypoint interno `web-internal` (`:8443`, HTTP plano), no por
  DNS directo;
- **centraliza la resiliencia E-W en Traefik**: circuit breakers y retries por
  servicio; el rate limit se aplica en el borde N-S.
- **aísla a los MS** de la web: ninguno publica puertos ni es alcanzable desde
  el host. Sólo mongo escucha en loopback (`127.0.0.1:27017`) para Compass.

El orquestador **no desaparece**: sigue siendo la lógica de negocio (valida,
deduplica, orquesta). 

**Fase 12:** la política de retry vuelve a Traefik; el orquestador conserva
una sola llamada por operación. Los **circuit breakers** y retries E-W viven
en Traefik. La **salud** del orquestador usa un `/readyz` **agregado** que
consulta a los microservicios a las rutas de salud de cada MS
(`extract:8080/healthz`, `persistence:8000/readyz`, `auditlog:8000/readyz`).
Las sondas van por **DNS directo** en la red interna (`backend`) y el tramo E-W
usa el entrypoint interno `http://traefik-internal:8443` (HTTP plano; ver §2.4).
`/healthz` del orquestador sigue siendo estático (vivacidad).

`X-Request-ID` se propaga entre orquestador y MS. Por decisión humana el stack
de observabilidad es **sólo logging**: no hay métricas (`/metrics` no existe),
no hay tracing y no hay Prometheus/Grafana. La visibilidad del comportamiento del
upstream se obtiene de los logs estructurados correlacionados por `X-Request-ID`.

---

## 2. Arquitectura

### 2.1 Topología y redes

```
                         Host / Internet
                               │
               :80 (301 → https)          :443 (TLS, mkcert)
                               │                │
                       ┌───────┴────────────────┴────────┐
                       │          Traefik v3.7.14        │
                       │  web :80   websecure :443        │
                       │  web-internal :8443  (HTTP, E-W)  │
                       └───┬───────────────────────┬──────┘
                           │                       │
                    edge   │                       │  backend  (internal: true)
                           │                       │
                    orchestrator ──────►  extract×5 · persistence · auditlog · mongo

   N-S : cliente ──► Traefik(443) ──► orchestrator            (H1 TLS + H3 HTTP/1.1)
   E-W : orchestrator ──► Traefik(8443) ──► MS               (H2b HTTP/1.1 + H3 HTTP/1.1)
```

| Red       | Tipo            | Quiénes                                              |
| --------- | --------------- | ---------------------------------------------------- |
| `edge`    | `bridge`        | Traefik, orquestador                                 |
| `backend` | `bridge` **`internal: true`** | Traefik, orquestador, extract×5, persistence, auditlog, mongo |
| `mongo-local` | `bridge` | mongo (sólo para publicar `27017` en loopback) |

- La red `backend` es **`internal: true`**: Docker no le da gateway a Internet.
  Los MS no pueden salir a la red pública y, sobre todo, el host no puede
  alcanzarlos: la única entrada es Traefik.
- El **orquestador está en ambas redes**: recibe de `edge` (lo público) y sale
  por `backend`.
- **`mongo-local` existe por una limitación de Docker**: no publica puertos de
  contenedores que sólo están en redes `internal`. Es un puente no interno al
  que sólo se une mongo, para publicar `27017` en loopback
  (`127.0.0.1:27017`, Compass). Mismo patrón que Consul (`consul_local` +
  `127.0.0.1:8501`).
- El **proyecto compose se llama `pdf-extractext`**, así que los nombres reales
  de red son `pdf-extractext_edge` y `pdf-extractext_backend`. Por eso el
  provider de Traefik fija `network: pdf-extractext_backend` (si no, Docker
  elige una red arbitraria).

### 2.2 Por qué un Traefik propio

- El repo del Extract trae su propio Traefik y la máquina tenía un Traefik
  compartido con `*.universidad.localhost`. Para no acoplar el proyecto a
  servicios externos, `deploy/` levanta **su propio** Traefik, aislado.
- Se fija la imagen **`traefik:v3.7.14`** (última de la línea 3.7): version
  pineada (no `v3.7` flotante, que cambiaría sola y es impredecible en un
  despliegue) y con las correcciones de CVE de la línea.
- El Traefik compartido de la máquina se detuvo y este usa `80`/`443`: son
  mutuamente excluyentes por diseño (nunca corren ambos).

### 2.3 Modelo de configuración: provider Consul Catalog + provider file

Traefik se configura con **dos providers** (ver `traefik/traefik.yml`):

| Provider | Rol | Dónde |
| -------- | --- | ----- |
| **consulCatalog** | *descubre servicios y routers* a partir de tags Consul | registro de cada servicio |
| **file**   | *define middlewares, TLS y transport* | `traefik/dynamic.yml` |

**Regla dura (para no duplicar configuración):**

> *router + service en tags Consul; lógica reutilizable en `dynamic.yml`.*

Un **router sólo puede referenciar un service del mismo provider**. Por eso cada
servicio registrado en Consul declara también su router mediante tags, así el
catálogo entrega el backend y su configuración de borde juntos:

```yaml
tags:
  - traefik.enable=true
  - traefik.http.routers.<router>.rule=<regla>
  - traefik.http.routers.<router>.entrypoints=<entrypoint>
  - traefik.http.routers.<router>.tls=true        # sólo routers N-S (websecure)
  - traefik.http.routers.<router>.middlewares=<mw1>@file,<mw2>@file
```

Los routers E-W (`web-internal`) **no** llevan `tls=true`: ese entrypoint es HTTP
plano. El único router con TLS es `orchestrator-public` (`websecure`, `:443`).

Los middlewares (headers, rate limit, breakers, retry), TLS y timeouts viven
centralizados en `dynamic.yml` y se consumen como `<nombre>@file`. Así, cambiar
la lógica de un middleware no obliga a tocar las labels de los contenedores.

El nombre, dirección y puerto de cada backend no se repiten en tags: Consul los
entrega como metadata nativa del servicio registrado. Los tags sólo contienen
la habilitación y la configuración de routers/middlewares.

### 2.4 TLS por tramo (y por qué se fuerza HTTP/1.1 hacia los backends)

Hay tres tramos, cada uno con su decisión:

| Tramo | Protocolo | Certificado | Por qué |
| ----- | --------- | ----------- | ------- |
| **H1** cliente → Traefik (`websecure:443`) | HTTPS | mkcert (`certs/traefik.pem`) | Lo único que ve el usuario; cert de desarrollo con los SANs del proyecto. |
| **H2b** orquestador → Traefik (`web-internal:8443`) | HTTP/1.1 **plano** | — | Corre sobre `backend`, la misma red donde H3 ya va en claro. |
| **H3** Traefik → MS (red `backend`) | HTTP/1.1 **plano** | — | Los MS solo escuchan HTTP; el segmento es una red Docker interna y aislada. |

**Por qué el E-W ya no va con TLS.** H2b y H3 comparten el segmento L2
(`backend`): cualquier contenedor capaz de sniffear el tramo cifrado podía ya
sniffear H3 en claro, o llamar al MS directamente sin pasar por Traefik. Cifrar
sólo el primer salto no aportaba confidencialidad y, a cambio, obligaba al
orquestador a montar la CA de mkcert (`SSL_CERT_FILE`), a mantener el SAN
`traefik` y a validar certificados en los tests. Se elimina esa complejidad y el
TLS queda donde sí es útil: el borde público. El aislamiento de la red E-W lo
sigue dando `backend` (`internal: true`, sin publicar puertos).

**Decisión crítica (`serversTransport.default.disableHTTP2: true`).** Por
defecto Traefik intenta **HTTP/2 sin TLS (h2c)** contra backends *cleartext*.
El *preface* de h2c (`PRI * HTTP/2.0`) **lo rechazan tanto Go `net/http`
(orquestador y Extract) como uvicorn**, que responden `505 HTTP Version Not
Supported`. Forzando **HTTP/1.1** hacia los backends se evita tocar el código de
los MS. Además se fija `responseHeaderTimeout: 35s` para que Traefik no corte la
respuesta antes que el deadline propio del orquestador (`HTTP_TIMEOUT=35s`) y
del Extract (30s).

> Nota de plan: `tasks/plan.md` §12 decisión #5 menciona `http2.enabled: false`;
> en v3.7 el campo correcto de `serversTransports` es **`disableHTTP2: true`**
> (el otro daba error de parseo `field not found, node: http2`). El archivo
> `dynamic.yml` usa el campo correcto.

### 2.5 Servicios, puertos y comandos

| Servicio | Imagen / build | Puerto interno | Réplicas | Publica |
| -------- | -------------- | -------------- | -------- | ------- |
| `traefik-public` / `traefik-internal` | `traefik:v3.7.14` | 80, 443, 8443, 8080 (API/ping interno) | 1 | **80:80, 443:443** |
| `orchestrator` | build `../validator/...` | 8080 | 1 | – |
| `extract` | build `../Conversor/extract-markdown-microservice-pdf-extractext` | 8080 | **5** | – |
| `persistence` | build `../persistence/PersistenceMicroservices-pdf-extractext` | 8000 | 1 | – |
| `auditlog` | build `../audit_log/audit-log-microservice-pdf-extractext` | 8000 | 1 | – |
| `mongo` | `mongo:7` | 27017 | 1 | `127.0.0.1:27017` (loopback, Compass) |

---

## 3. Estructura de archivos

```
deploy/
├── Makefile                  # operación + tests (deploy ordenado, test, test-cb, ...)
├── compose.yaml              # stack unificado (6 servicios, 2 redes + mongo-local, 1 volumen)
├── .env.example              # plantilla de variables (copiar a .env)
├── .gitignore                # ignora .env y el material de CA
├── README.md                 # este archivo
├── certs/
│   ├── generate-certs.sh     # genera el TLS de desarrollo con mkcert
│   ├── traefik.pem           # (gitignored) cert que sirve Traefik
│   ├── traefik-key.pem       # (gitignored) private key
│   └── rootCA.pem            # (gitignored) CA de mkcert para el orquestador
├── scripts/
│   ├── retry-stub.py         # backend de fallo intermitente (pruebas de retry)
│   └── verify-retries.sh     # verifica los middlewares retry de Traefik
├── tests/
│   ├── lib.sh                # helpers compartidos (aserciones, clientes N-S/E-W)
│   ├── run-all.sh            # corre toda la batería
│   ├── 01-operational.sh     # operatividad E2E de TODOS los servicios
│   ├── 02-network.sh         # aislamiento de red y endurecimiento
│   ├── 03-rate-limit.sh      # rate limit del borde (429)
│   ├── 04-circuit-breaker.sh # circuit breaker E-W (503 + recuperación)
│   ├── 05-retry.sh           # middlewares de retry E-W
│   └── 06-consul-lifecycle.sh # baja graceful y purga crítica en Consul
└── traefik/
    ├── traefik.yml           # config ESTÁTICA (entrypoints, providers, log, ping)
    └── dynamic.yml           # config DINÁMICA (middlewares, TLS, transport)
```

**Qué hace cada archivo y por qué existe:**

- **`Makefile`** — interfaz de operación y pruebas. El target `deploy`/`up`
  implementa el **arranque ordenado por fases** (ver §6.3) y `test` corre la
  batería completa (ver §7.x).
- **`tests/`** — tests de usuario ejecutables por `make test*`: operatividad E2E,
  aislamiento, rate limit, circuit breaker y retry.
- **`compose.yaml`** — único punto de orquestación. Define las redes (`edge`,
  `backend` externa y `mongo-local` de publicación) y el
  volumen, y todos los servicios con su hardening. Que todo el sistema se
  levante con un `docker compose up -d` es el objetivo de la fase (el orden fino
  lo da el Makefile, no `depends_on`; ver §4.5).
- **`traefik/traefik.yml`** (estática) — se lee al arrancar y *no* se recarga en
  caliente. Aquí van: entrypoints (`web`, `websecure`, `web-internal`),
  providers (`docker`, `file`), `log`, `accessLog`, `ping` (el endpoint del
  healthcheck). La config estática no puede vivir en el provider file.
- **`traefik/dynamic.yml`** (dinámica) — se recarga sola (`watch: true`) sin
  cambiar tráfico: aquí van los `certificates`, `serversTransport` y los
  middlewares (seguridad, rate limit, breakers, retries). Los **routers** se
  declaran en las labels del `compose.yaml` (mismo provider que sus services).
- **`certs/generate-certs.sh`** — genera un cert de desarrollo válido para los
  hosts del proyecto y deja la CA de mkcert disponible para el orquestador.
- **`scripts/retry-stub.py`** + **`scripts/verify-retries.sh`** — reproducen y
  verifican de forma *determinista* que los retries de Traefik funcionan (§8.4).
- **`.gitignore`** — evita commitear secretos (`.env`) y material de CA
  (`certs/*.pem`, `certs/*.key`).

---

## 4. Decisiones de diseño (y por qué)

### 4.1 Decisiones de arquitectura (cerradas con el humano)

1. **Traefik propio en `deploy/`, imagen `traefik:v3.7.14`.**
   *Por qué:* Consul necesita `consulCatalog` y el entrypoint E-W interno; la
   versión pineada da un despliegue reproducible.

2. **Un solo router público hacia el orquestador.**
   `orchestrator-public` (declarado en la label del orquestador) en `websecure`
   con `Host('pdf-extractext.localhost') && PathPrefix('/api')` →
   `orchestrator@docker`. `/healthz` y `/readyz` **no** se exponen por web (solo
   los consume el healthcheck por `localhost`).
   *Por qué:* una superficie pública mínima y explícita.

3. **TLS por tramo (H1 / H2b / H3)** — ver §2.4.
   *Por qué:* el tramo externo va con TLS real; los dos tramos internos van en
   claro sobre `backend`, que es una red Docker aislada y sin puertos publicados.

4. **Router + service en el provider docker; middlewares/TLS/transport en el file provider.**
   Ver §2.3. *Por qué:* un router sólo referencia services de su provider; tener
   router y service juntos elimina la referencia cruzada `router@file ->
   service@docker` y el `the service "X@docker" does not exist` del arranque,
   sin perder la centralización de la lógica reutilizable en `dynamic.yml`.

5. **`serversTransport.default`: `disableHTTP2: true` + `responseHeaderTimeout: 35s`.**
   Ver §2.4. *Por qué:* evita el `505` de h2c y alinea timeouts con el
   orquestador.

6. **Dos redes de datos: `edge` y `backend` (`internal: true`); solo Traefik
   publica en la red.**
   *Por qué:* aislar el plano de datos; los MS no son alcanzables desde el host.
   Única publicación extra al host: mongo en loopback (`127.0.0.1:27017`, ver #7
   y D12.5).

7. **Mongo incluido en la red `backend`, con volumen nombrado `mongo-data`,
   publicado sólo en loopback (`127.0.0.1:27017:27017`).**
   *Por qué:* persistence y auditlog necesitan Mongo; incluirlo evita un
   prerequisito externo. El volumen evita perder datos con un reinicio.
   Bases: `pdf_extractext` (persistence) y `pdf_extractext_audit` (audit).
   El bind a `127.0.0.1` permite inspeccionarlo desde el host con Compass
   (`mongodb://127.0.0.1:27017`) sin exponer el puerto a otras interfaces.
   Como Docker no publica puertos desde redes `internal`, la publicación viaja
   por el puente no interno `mongo-local` (sólo mongo lo usa; mismo patrón que
   Consul con `consul_local`). `make test-network` lo verifica explícitamente.

8. **Un único secreto por MS, compartido con el orquestador.**
   El MS lo exige como `SERVICE_API_TOKEN`; el orquestador lo emite como
   `PERSISTENCE_API_TOKEN` / `AUDIT_LOG_API_TOKEN`. Deben coincidir.
   *Por qué:* cada MS autentica a su cliente con su propio token.

9. **Resiliencia en Traefik; el orquestador solo propaga el `503`.**
   Ver §8. Incluye rate limit, circuit breakers por servicio y retries.
   *Por qué:* el borde es el lugar correcto para protegerse (una sola vez para
   todos los flujos) y deja al orquestador enfocado en la lógica.

10. **Config de infra por `env` en el compose; los defaults de Go NO cambian
    (desvío D11.3).** Las base URLs de los MS se setean en el compose
    (`..._BASE_URL=http://traefik-internal:8443`). Los defaults de
    `internal/config/config.go` siguen apuntando a `localhost` para el dev sin
    Traefik.
    *Por qué:* la configuración de infraestructura vive en la capa de
    infraestructura (DI/compose); mutar los defaults de Go rompería el desarrollo
    local y los tests de configuración.

### 4.2 Decisiones asumidas

| # | Decisión | Valor | Por qué |
| - | -------- | ----- | ------- |
| D12.1 | ¿Dashboard/webUI de Traefik expuesto? | **No** | Superficie de exposición innecesaria; se usan logs. (Se habilitó `api` solo de forma temporal durante la investigación de §10.) |
| D12.2 | ¿Mongo con volumen persistente? | **Sí** (`mongo-data`) | No perder datos al recrear contenedores; solo `down -v` borra. |
| D12.3 | ¿Access log de Traefik además del del orquestador? | **Sí**, a stdout | Da la **IP real** del cliente (`X-Forwarded-For`); en el access log del orquestador `remote_addr` es la IP del contenedor Traefik. |
| D12.4 | ¿Cert de dev por host o por SNI? | Un único cert mkcert multi-SAN | Un solo archivo sirve para todos los SNI (`pdf-extractext.localhost`, `*.pdf-extractext.localhost`, `traefik`, `localhost`, `127.0.0.1`, `::1`). |
| D12.5 | ¿Mongo alcanzable desde el host (Compass)? | **Sí**, sólo loopback (`127.0.0.1:27017:27017`) vía el puente no interno `mongo-local` | Inspección local con Compass (`mongodb://127.0.0.1:27017`) sin exponer el puerto a otras interfaces; lo verifica `make test-network`. |

### 4.3 Decisión sobre el provider Docker y servicios caídos

Se activó **`providers.docker.allowEmptyServices: true`** (en `traefik.yml`).
Es la opción **documentada** para que, cuando todos los contenedores de un
servicio quedan *unhealthy*, Traefik mantenga el servicio (vacío) y responda
**`503`** en vez de eliminar el router (**`404`**).

**Hallazgo importante (verificado en v3.7.14):** con un contenedor que **nunca
llega a `healthy`** (healthcheck fallando desde el arranque) esta opción
devuelve **`500 Internal Server Error`**, no el `503` documentado. Es un bug
abierto de Traefik ([issue #13261](https://github.com/traefik/traefik/issues/13261)).

Se deja **activa** igual porque: (a) es la vía documentada y será correcta
cuando el bug se arregle; (b) **no empeora** lo visible (sin la opción el router
también se cae). El `503` **confiable** frente a un MS caído lo da el **circuit
breaker** cuando el servidor *está presente pero falla* (ver §8.3). El detalle
completo y las alternativas están en §10.

### 4.4 Otras decisiones de implementación

- **`certs/generate-certs.sh` deja la key en modo `644`.**
  *Por qué:* Traefik corre con `cap_drop: [ALL]` (sin `DAC_OVERRIDE`), así que
  **no puede leer `traefik-key.pem` en `600` aunque sea root**. Son certs de
  desarrollo; se dejan legibles a propósito.
- **`network: pdf-extractext_backend` en el provider docker.**
  *Por qué:* sin esto Traefik avisa `Could not find network named backend` y cae
  a la primera red del contenedor (indeterminista).
- **`auditlog` integrado al stack base (ya tiene Dockerfile).**
  El Dockerfile de AUDA escucha en **`:8000`** y trae su propio HEALTHCHECK
  `/health`. El compose **no** sobreescribe `command` (usa el del Dockerfile) y
  la label apunta a `8000`.
- **`LOG_LEVEL` de `.env` cableado al comando de Traefik**
  (`--log.level=${LOG_LEVEL:-info}`): el CLI overridea el `log.level` de la
  config estática, así que el `.env` tiene efecto real.

### 4.5 Orden de arranque: por Makefile, sin `depends_on`

**Decisión:** el `compose.yaml` **no** declara `depends_on`. El orden de arranque
lo garantiza el target `deploy`/`up` del `Makefile`, que levanta por fases y
**espera el health real** de cada fase antes de pasar a la siguiente:

| Fase | Servicios | Espera antes de continuar |
| ---- | --------- | ------------------------- |
| 1 | `mongo` | `healthy` (backing store listo) |
| 2 | `traefik-public` / `traefik-internal` | `healthy` (borde listo para enrutar) |
| 3 | `kv-seed` (4 prefijos) + `extract`, `persistence`, `auditlog` | `healthy` de `persistence`/`auditlog` (`extract` no define `HEALTHCHECK`) |
| 4 | — (sólo espera) | **Consul reporta `passing` cada instancia de los tres** |
| 5 | `orchestrator` | `healthy` (entrada, usa a los anteriores) |
| 6 | — (reconciliación) | purga de registros obsoletos de este nodo |

Las fases 1, 2, 3 y 5 usan
`docker compose up -d --wait --wait-timeout <WAIT_TIMEOUT> <svcs>`.
La fase 3 siembra el KV **antes** de levantar los servicios de negocio: los
cuatro leen su prefijo al arrancar y un prefijo ausente es error fatal, así que
en un Consul limpio el seed tiene que existir antes del primer `up`.
La fase 4 es la que garantiza que el orquestador no arranque antes de que sus
dependencias estén realmente enrutables: `scripts/wait-consul-passing.sh`
consulta `/v1/health/service/<svc>?passing=true` y exige que **cada contenedor
en ejecución** de `extract`, `persistence` y `auditlog` tenga su `ServiceID` en
`passing`. Es la misma señal que usa el provider `consulCatalog` de Traefik, así
que cubre el caso de `extract` (sin `HEALTHCHECK`) y el de cualquier instancia
que todavía no terminó de registrarse. Si vence `WAIT_TIMEOUT`, `make up` falla
con el estado de cada check en vez de arrancar el orquestador con ruteo roto.

Al terminar, `make up` reconcilia Consul contra los IDs de los contenedores
actuales y elimina registros antiguos de este mismo nodo; registros de otros
nodos se conservan.

*Por qué no `depends_on`:*

- `depends_on` solo controla el **orden de creación**, no que el servicio esté
  **listo** (`depends_on: [mongo]` no implica que Mongo ya acepte queries). La
  forma correcta de expresar "B necesita a A *listo*" es el **healthcheck**; el
  Makefile lo aprovecha con `--wait` donde existe, y con el estado `passing` de
  Consul donde no (`extract` corre en una imagen sin shell y no define
  `HEALTHCHECK`).
- El orden por fases es **explícito y auditable** (se ve la secuencia en la
  salida de `make up`) y no acopla el `compose.yaml` a una topología de arranque
  que el provider Docker resuelve igual en runtime.
- Si se corre `docker compose up -d` directo (sin el Makefile), los contenedores
  arrancan en paralelo y **convergen solos** gracias a los healthchecks y a
  `restart: unless-stopped`; el Makefile solo evita el transitorio de arranque en
  frío.

---

## 5. Requisitos

- Docker + el plugin `docker compose` (`docker compose ...`).
- [`mkcert`](https://github.com/FiloSottile/mkcert) para el TLS de desarrollo.
- Para la batería de tests (`make test`): `curl`, `docker`, `python3` (parseo de
  JSON) y `vegeta` para el rate limit (si falta, cae a `curl`+`xargs`). Opcional
  para pruebas de carga manuales: `k6` (compose locales del validador).

---

## 6. Puesta en marcha paso a paso

> Todos los comandos asumen que estás **parado en `deploy/`**.

### 6.1 Generar el TLS de desarrollo

```bash
./certs/generate-certs.sh
```

Qué hace:

1. `mkcert -install` — instala la CA raíz de mkcert en el sistema (confianza).
2. Genera `certs/traefik.pem` + `certs/traefik-key.pem` con los SANs del proyecto.
3. Copia `$(mkcert -CAROOT)/rootCA.pem` a `certs/rootCA.pem`.
4. `chmod 644` sobre los tres archivos (ver §4.4).

*Por qué:* Traefik necesita cert+key para servir TLS en `:443`, y la CA
(`rootCA.pem`) se usa desde el host con `curl --cacert` y en los tests del borde
público.

### 6.2 Configurar variables de entorno y red

```bash
make network       # crea pdf-extractext_backend (internal) si no existe
cp .env.example .env
# editar CONSUL_CA_FILE y tokens de Consul
```

- `deploy/.env` es **bootstrap**: dirección/CA/tokens de Consul y parámetros de infraestructura.
- `CONSUL_ENABLED` es variable de entorno fijada a `"true"` en `compose.yaml`; no va en `.env` ni en KV.
- La configuración funcional de los 4 servicios se siembra en Consul KV desde `deploy/kv/<servicio>.env` (`orchestrator`, `extract`, `persistence`, `auditlog`) con `make kv-seed` (usa `docker exec` + `CONSUL_KV_SEED_TOKEN`, un token dedicado con `key:write` sólo bajo `pdf-extractext/dev/`).
- `make kv-seed` es idempotente y no destructivo: escribe clave por clave y no borra claves existentes. Sembrar es obligatorio porque un prefijo ausente (HTTP 404) es error fatal de arranque en los 4 servicios; persistence además rechaza un prefijo vacío.
- Los tokens de API (`PERSISTENCE_API_TOKEN`, `AUDIT_LOG_API_TOKEN`, `SERVICE_API_TOKEN`) **no** se siembran: son secretos y viven en el entorno de compose (fallback) o en el KV ya cargado.
- Consul debe estar corriendo en `backend` con `container_name: consul`. Su UI/API se publica **sólo en loopback** (`127.0.0.1:8501`), nunca en `0.0.0.0` ni por Traefik. Levántalo desde `/home/francocp12/Documents/Services/consul`; `make check-consul` valida esa regla y `make consul-ui` muestra la URL y el CA.
- El `.gitignore` excluye `.env`: **nunca** se commitean tokens.

### 6.3 Levantar el stack (arranque ordenado)

```bash
make certs
make kv-seed       # siembra los 4 prefijos; requiere Consul arriba en backend
make deploy        # build + arranque por fases + espera healthy (primera vez)
make up            # arranque por fases sin rebuild (uso habitual)
make ps            # estado de los contenedores
```

`make up` levanta en fases esperando el `healthy` de cada una y, antes de la
entrada, el `passing` de Consul:

```
>> [1/6] mongo
>> [2/6] traefik-public, traefik-internal
>> [3/6] seed KV (4 prefijos) + extract, persistence, auditlog
>> [4/6] Consul: esperando a que los servicios de negocio estén passing
>> [5/6] orchestrator (entrada; relee KV con --force-recreate)
>> [6/6] Consul: reconciliando registros
```

Qué pasa por dentro:

- Se construyen/levantan los 6 servicios; Traefik publica `80`/`443`, mongo
  publica `27017` sólo en loopback (`127.0.0.1`) y el resto no publica nada.
- La fase 3 siembra los 4 prefijos KV y recién después levanta
  `extract`, `persistence` y `auditlog`, que leen su configuración al arrancar.
- Los MS se registran en Consul y Traefik los descubre mediante `consulCatalog`.
  La fase 4 espera a que ese registro esté `passing` para las tres dependencias
  del orquestador (ver §4.5); `make wait-consul` expone la espera por separado.
- Al terminar el arranque, se eliminan los IDs viejos de servicios del nodo
  Consul usado por este deploy, incluidos stubs de pruebas que hayan quedado.
- `CONSUL_HTTP_ADDR`, los tokens ACL y la ruta de la CA son bootstrap y quedan
  fuera del KV; la configuración funcional se carga desde el prefijo KV de cada
  servicio.
- Los healthchecks determinan el estado `(healthy)` de cada fase.

> Alternativa sin Makefile: `docker compose up -d` (paralelo; converge solo por
> healthchecks + `restart`, sin garantizar el orden).

### 6.4 Bajar el stack

```bash
make down                  # = docker compose down (conserva el volumen de mongo)
make clean                 # = docker compose down -v --remove-orphans (BORRA datos)
```

*Por qué `-v` es explícito:* evita borrar datos por accidente (D12.2).

---

## 7. Verificación paso a paso

Cada comando prueba una decisión concreta. Se usa `--resolve` para no depender
de `/etc/hosts` y `--cacert certs/rootCA.pem` para confiar en el cert de dev.

```bash
# (1) HTTP -> HTTPS: 301 permanente
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost/            # → 301

# (2) Host desconocido: 404
curl --cacert certs/rootCA.pem -sS -o /dev/null -w '%{http_code}\n' \
  https://localhost/                                                   # → 404

# (3) Sin Content-Type: 415
curl --cacert certs/rootCA.pem -sS -o /dev/null -w '%{http_code}\n' \
  --resolve pdf-extractext.localhost:443:127.0.0.1 \
  -X POST https://pdf-extractext.localhost/api/v1/pdfs/extract         # → 415

# (4) Extracción real: 200 y checksum == SHA-256(bytes)
PDF=../Conversor/testdata/2020-Scrum-Guide-Spanish-Latin-South-American.pdf
curl --cacert certs/rootCA.pem -sS \
  --resolve pdf-extractext.localhost:443:127.0.0.1 \
  -H 'Content-Type: application/pdf' --data-binary "@$PDF" \
  https://pdf-extractext.localhost/api/v1/pdfs/extract                 # → 200 + JSON
sha256sum "$PDF"   # debe coincidir con el campo "checksum"

# (5) Auditoría (auditlog ya integrado): 200
curl --cacert certs/rootCA.pem -sS \
  --resolve pdf-extractext.localhost:443:127.0.0.1 \
  "https://pdf-extractext.localhost/api/v1/audit/logs?limit=5"         # → 200 {"logs":[...]}
```

Resultados medidos / esperados:

- (1) `301`; (2) `404`; (3) `415`; (4) `200` con
  `checksum=6bbff3f361e52016cbb75a72671f1b31b5e043fdc1cc3f022f1b15a32795a256`
  y `page_count` = 16; (5) `200` con los eventos `pdf.extract` registrados.

### Verificar el aislamiento de red

```bash
docker network inspect pdf-extractext_backend | grep -i internal   # → "internal": true
docker inspect pdf-extractext-extract-1 \
  --format '{{json .NetworkSettings.Ports}}'                        # → {} (sin publicar)
docker inspect pdf-extractext-mongo-1 \
  --format '{{json .HostConfig.PortBindings}}'                      # → 27017 sólo en 127.0.0.1
```

Mongo desde el host (Compass): `mongodb://127.0.0.1:27017` — el puerto se
publica **sólo en loopback** (D12.5).

### 7.1 Batería de tests automatizada (`make test`)

Todos los tests se corren **desde el deploy** y verifican el sistema funcionando
de verdad (no mocks). El `Makefile` primero asegura el stack arriba (`up`) y
luego ejecuta los tests; cada uno imprime `ok`/`FAIL` y un `RESULTADO` final.

```bash
make test              # TODA la batería (01..05)
make test-operational  # sólo operatividad E2E de todos los servicios
make test-network      # sólo aislamiento de red y endurecimiento
make test-ratelimit    # sólo rate limit del borde
make test-cb           # sólo circuit breaker
make test-retry        # sólo retry
make test-consul-lifecycle # baja graceful y purga crítica en Consul
```

| Target | Script | Qué prueba | Cobertura de servicios |
| ------ | ------ | ---------- | ---------------------- |
| `test-operational` | `tests/01-operational.sh` | **Operatividad de punta a punta**: salud de todo el stack, réplicas de extract, borde N-S (301/404/415/cabeceras), extracción real (checksum == SHA-256), persistencia (escritura/lectura + dedup), CRUD de textos, auditoría y datos en Mongo | **todos**: traefik, orchestrator, extract×5, persistence, auditlog, mongo |
| `test-network` | `tests/02-network.sh` | Red `backend` `internal:true`; MS sólo en backend; **sólo Traefik publica en la red** (excepciones explícitas en loopback: mongo `127.0.0.1:27017` para Compass, Consul `127.0.0.1:8501`); host no alcanza los MS; `no-new-privileges`, `cap_drop ALL`, `read_only`, sin `docker.sock` (descubrimiento vía Consul) | infra |
| `test-ratelimit` | `tests/03-rate-limit.sh` | Ráfaga con `vegeta` por encima de `average 50/s` ⇒ aparecen `429` y respuestas permitidas | traefik (borde) |
| `test-cb` | `tests/04-circuit-breaker.sh` | Con un backend presente que **siempre falla** (stub): 1º `502`, luego el breaker abre ⇒ `503`; al restaurar ⇒ `200` | traefik E-W + extract |
| `test-retry` | `tests/05-retry.sh` | Extract: POST con un retry; Persistence: GET con un retry y POST sin retry | traefik E-W |
| `test-consul-lifecycle` | `tests/06-consul-lifecycle.sh` | Stop graceful elimina agente/catálogo; re-registro; purga tras quedar crítico; recuperación. **Sin borrado manual del catálogo** | orchestrator + Consul + traefik N-S |

Detalles de implementación:

- **`tests/lib.sh`** — helpers comunes: aserciones (`assert_status`, `assert_eq`,
  `assert_ge`, ...), cliente N-S (`api_*` con `--cacert` + `--resolve`) y cliente
  E-W (`ew`), que corre un contenedor efímero en la red `backend` para pegarle al
  entrypoint interno `http://traefik-internal:8443`.
- **`tests/run-all.sh`** — corre 01..06 y agrega el resultado por test.
- **`tests/06-consul-lifecycle.sh`** — detiene y pausa el orquestador para probar
  las dos vías de limpieza de Consul. Nunca usa `/v1/catalog/deregister`; un EXIT
  trap lo despausa/reinicia y espera que quede healthy. La fase crítica puede
  demorar aproximadamente 90 segundos por el intervalo del reaper.
- Los tests del borde que necesitan un backend "roto" usan
  `scripts/retry-stub.py` (fallo intermitente/constante) y **restauran** el estado
  real al terminar. Como el router vive en el mismo contenedor que su service
  (§2.3), el stub que reemplaza a un MS declara **también el router** (`_ew_router_labels`
  en `tests/lib.sh`): si no,
  al detener el MS real desaparece el router y el request daría `404` en vez de
  llegar al stub.
- Requisitos: `curl`, `docker`, `python3` (parseo de JSON) y, para el rate limit,
  `vegeta` (si falta, `03` cae a un generador con `curl`+`xargs`).

Resultado esperado (medido en esta máquina):

```
01-operational.sh          ok   (31 ok, 0 fallidos)
02-network.sh              ok   (47 ok, 0 fallidos)
03-rate-limit.sh           ok   (~900×429, ~300 permitidas)
04-circuit-breaker.sh      ok   (502 → 503 → recuperación 200)
05-retry.sh                ok   (Extract y Persistence con sus políticas)
06-consul-lifecycle.sh     ok   (11 ok, 0 fallidos; graceful + crítico)
TODOS LOS TESTS OK
```

---

## 8. Comportamiento del borde (medido)

Los routers se declaran en los tags del registro Consul (`consulCatalog`); los
middlewares de defensa se definen en `traefik/dynamic.yml` (provider file) y se
aplican en orden *security-headers → circuit-breaker → retry*.

| Router | Entrypoint | Regla | Servicio | Middlewares (en orden) |
| ------ | ---------- | ----- | -------- | ---------------------- |
| `orchestrator-public` | `websecure` | `Host(...) && PathPrefix(/api)` | `orchestrator@consulcatalog` | `security-headers`, `api-ratelimit`, `orchestrator-cb` |
| `extract-ew` | `web-internal` | `PathPrefix(/extract)` | `extract@consulcatalog` | `security-headers`, `extract-cb`, `extract-retry` |
| `texts-ew` | `web-internal` | `PathPrefix(/texts)` | `persistence@consulcatalog` | `security-headers`, `persistence-cb`, `persistence-retry` |
| `audit-ew` | `web-internal` | `PathPrefix(/audit)` | `auditlog@consulcatalog` | `security-headers`, `audit-cb` |

### 8.1 Cabeceras de seguridad (`security-headers`)

`SAMEORIGIN` (anti-clickjacking), `X-Content-Type-Options: nosniff`,
`X-XSS-Protection`, `Referrer-Policy: no-referrer`, `Permissions-Policy`. Se
aplican a N-S y E-W. *Por qué:* endurecer respuestas sin depender de la app.

### 8.2 Rate limit → `429` (`api-ratelimit`)

`rateLimit{average: 50, burst: 100}` **por IP real** (Traefik es el borde, así
que ve la IP del cliente). La prueba automatizada dispara una ráfaga y verifica
que aparecen `429` y respuestas permitidas.

```bash
make test-ratelimit
```

**Medido:** `2000` requests → **`599×200`, `1401×429`** (~70% rechazado). El
`429` protege los MS de picos desde internet.

*Prueba manual alternativa (opcional):* con un PDF ya persistido y `vegeta`,
crear `t.json` a partir de un POST del PDF (ver utilidades del validador) y
ejecutar vegeta apuntando a `https://127.0.0.1/api/...` con `-insecure` y
`Host: pdf-extractext.localhost`.

### 8.3 Circuit breaker → `503` (`extract-cb`, …)

Cada servicio tiene un breaker con
`NetworkErrorRatio() > 0.30 || ResponseCodeRatio(500,600,0,600) > 0.30`. El
breaker queda **fuera** del retry: cuando abre, responde `503` directo sin volver
a golpear al MS. El orquestador **propaga** ese `503` (cambio Go de la Fase 11:
`httpclient.StatusError` ⇒ los handlers mapean `503→503`, el resto de fallos
upstream → `502`).

**Reproducción** (backend presente pero fallando, p. ej. con el stub que siempre
devuelve 502, o un MS cuyo proceso murió pero el contenedor sigue):

```bash
# 1ª petición: breaker cerrado -> 502 (backend inalcanzable)
# siguientes: el breaker abre -> Traefik responde 503, el orquestador lo propaga
```

**Medido** con `vegeta` a 3 req/s: `Status Codes  [code:count]  502:1  503:35`.
Al volver el MS el breaker se cierra solo y el servicio retoma `200`
(auto-recuperación).

### 8.4 Retries E-W

```bash
./scripts/verify-retries.sh
```

El script `scripts/retry-stub.py` permite comprobar los reintentos de Traefik:
devuelve `502` las primeras `N` peticiones y luego `200`.

| Caso | Middleware | Petición | Resultado cliente | Intentos vistos |
| ---- | ---------- | -------- | ----------------- | --------------- |
| Extract | `extract-retry` (1 retry) | `POST /extract` | `200` | **2** |
| Persistence, idempotente | `persistence-retry` (1 retry) | `GET /texts` | `200` | **2** |
| Persistence, no idempotente | `persistence-retry` (POST excluido) | `POST /texts` | `502` | **1** |

`POST /texts` no se reintenta: aunque el checksum impide crear dos documentos,
un replay tras una escritura confirmada devuelve `409` en vez de la respuesta
original. Extract sí admite replay porque la extracción no crea ese registro.

Los dos middlewares hacen un único retry para `502-504`, con backoff corto.
Extract habilita el replay de POST y limita el cuerpo a 16 MiB para aceptar PDF
de hasta 15 MiB. Persistence mantiene deshabilitado el replay de POST/PATCH/LOCK;
Audit no tiene retry. El circuit breaker va antes que el retry: cuando está
abierto, devuelve `503` sin volver al backend.

---

## 9. Fase 12: salud y configuración del orquestador

La política de retry vive en Traefik. El orquestador configura una sola llamada
por operación (`RETRY_MAX_ATTEMPTS=1` en su prefijo de Consul KV), para evitar
que los intentos se multipliquen entre capas.

### 9.1 Salud agregada (`/readyz`)

- `GET /healthz` (orquestador): **liveness** — responde `200 OK` sin consultar a los MS.
- `GET /readyz` (orquestador): **readiness agregado** — consulta en paralelo a:
  - `http://extract:8080/healthz` (Extract)
  - `http://persistence:8000/readyz` (Persistence)
  - `http://auditlog:8000/readyz` (Audit Log)
- Cada probe tiene **timeout** (`HEALTH_CHECK_TIMEOUT`, por defecto `2s`) y solo se considera `OK` si HTTP `2xx`. Redirecciones (`3xx`) se tratan como `down`.
- Respuesta `200 OK` si **todos** los dependientes están `OK`. Si alguno está `down`, responde `503 Service Unavailable` con reporte por dependencia (`status`, `detail`, `duration_ms`).
- Las comprobaciones usan los `*_HEALTH_URL` configurados. Apuntan por
  **DNS directo** a los nombres de servicio Docker de la red `backend` (no pasan
  por Traefik), lo que evita bucles y mantiene la semántica de readiness real.

### 9.2 Presupuesto de retry

El orquestador carga configuración funcional desde Consul KV al arrancar. En el
prefijo indicado por `CONSUL_ORCHESTRATOR_KV_PREFIX`, configurar
`RETRY_MAX_ATTEMPTS=1` para desactivar sus reintentos. Las variables de entorno
de Compose son fallback para el modo local sin Consul y no sustituyen ese valor
en despliegue.

### 9.3 Trazabilidad y observabilidad

Por decisión humana el stack de observabilidad es **sólo logging**: no hay
métricas, no hay tracing y no se despliega Prometheus ni Grafana.

- `X-Request-ID` se genera en el orquestador si no viene, se propaga a todos los MS upstream y se devuelve en la respuesta. Se registra en los logs de acceso (excluyendo los health endpoints).
- El access log del orquestador registra método, ruta, status, tamaño, duración, `request_id` y `remote_addr`. Nunca registra cabeceras, cuerpos ni el contenido del PDF.
- El nivel de la línea de acceso sigue al status: 5xx ⇒ ERROR, 4xx ⇒ WARN, el resto ⇒ INFO.
- Los valores que vienen de fuera (cabeceras, URLs de servicio, mensajes de panic) se acotan en longitud y las URLs pierden credenciales, query y fragmento antes de escribirse.
- Los errores de `net/http` llegan envueltos en un `*url.Error` que incluye la URL completa: se registra sólo el error de verdad (`logging.SafeError`), sin la URL, para que un token en el query string de una URL de servicio no llegue al log.
- Una request que termina en panic queda registrada igual en el access log, con su `500`: el recovery va dentro del log de acceso, no al revés.
- Circuit breakers siguen en Traefik (defensa en borde). Retries **fuera** del breaker.

### 9.4 Variables de entorno (orquestador en Docker)

El `compose.yaml` del orquestador ahora inyecta:

- `EXTRACT_HEALTH_URL` (default: `http://extract:8080/healthz`)
- `PERSISTENCE_HEALTH_URL` (default: `http://persistence:8000/readyz`)
- `AUDIT_LOG_HEALTH_URL` (default: `http://auditlog:8000/readyz`)
- `HEALTH_CHECK_TIMEOUT` (default: `2s`)
- `RETRY_MAX_ATTEMPTS` (en Consul KV; debe ser `1` cuando Traefik reintenta)

**Healthcheck del contenedor** pasa a `wget -qO- http://127.0.0.1:8080/readyz` (antes `/healthz`). Esto asegura que el orquestador solo se marque `healthy` cuando **todos** sus dependientes estén listos.

### 9.5 Ciclo de vida en Consul y caída del orquestador

Consul distingue el estado local del agente del catálogo global que consume
Traefik. Una respuesta exitosa de `/v1/agent/service/deregister` no basta: el
agente debe propagar la baja al catálogo mediante *anti-entropy*. Para eso usa un
token interno dedicado, instalado por el bootstrap externo
`/home/francocp12/Documents/Services/consul/scripts/bootstrap-agent-acl.sh`.
Su política (`config/agent-policy.hcl`) solo escribe el nodo `ds` y lee servicios;
no se amplían los tokens anónimo, de management o de las aplicaciones. El token
persiste entre restarts con `acl.enable_token_persistence: true`.

Los cuatro servicios registran checks HTTP cada 10 segundos con
`DeregisterCriticalServiceAfter: "1m"`:

- **Shutdown graceful:** el servicio se da de baja del agente y del catálogo;
  Traefik converge en su refresh de 2 segundos y deja de usar ese upstream.
- **Proceso caído o contenedor sin responder:** el check queda crítico y el reaper
  purga la instancia después del minuto configurado, con una demora adicional
  periódica. No reemplaza a la baja graceful.
- **Restart:** la instancia vuelve a registrarse con el ID de su hostname actual.

El certificado de Consul también debe incluir `server.dc-converter.consul` para
el RPC TLS interno. `renew-server-cert.sh` lo renueva conservando CA y clave;
después se ejecuta `docker compose restart consul` en el deploy externo. Los
comandos y el diagnóstico completo están en `CONSUL-SPEC.md` y en el README de ese
Consul.

**Disponibilidad:** actualmente hay un solo orquestador y es la única entrada de
negocio pública (`/api`). Si se detiene, Extract, Persistence, Audit Log, Mongo y
Traefik pueden seguir healthy, pero el usuario no puede usar los flujos que pasan
por el orquestador. Durante la convergencia o con el breaker abierto la respuesta
puede ser `503`; cuando desaparece el router dinámico también puede ser `404`.
Evitar ese punto único de falla requiere una decisión separada de réplicas/HA, no
una limpieza manual de Consul.

`make test-consul-lifecycle` prueba estos comportamientos reales sin borrar
manualmente el catálogo y restaura el orquestador al terminar.

## 10. Endurecimiento

Aplicado en `compose.yaml`:

- **Red `backend` `internal: true`** — los MS no salen a Internet ni son
  alcanzables desde el host. Verificable con `docker network inspect`.
- **Solo Traefik publica en la red** `80`/`443`. Mongo publica `27017` **sólo
  en loopback** (`127.0.0.1:27017:27017` en el compose, para Compass), vía el
  puente no interno `mongo-local` que sólo mongo usa; Consul hace lo propio
  con su UI/API (`127.0.0.1:8501`). El resto **no** tiene `ports:`.
- **Mounts `:ro`** — `traefik.yml`, `entrypoint.sh`, `dynamic.yml`, `certs/` y
  la CA de Consul se montan read-only: Traefik solo los lee. El socket de Docker
  **no** se monta: el descubrimiento es vía Consul Catalog.
- **`security_opt: [no-new-privileges:true]`** en todos — impide escalar
  privilegios vía setuid.
- **`cap_drop: [ALL]`** con capacidades mínimas:
  - Traefik: `NET_BIND_SERVICE` (enlazar 80/443, puertos privilegiados).
  - Mongo: `CHOWN`, `SETUID`, `SETGID`, `FOWNER`, `DAC_OVERRIDE` (las que exige
    el entrypoint oficial para preparar el volumen y bajar a usuario `mongodb`).
- **`read_only: true` + `tmpfs: /tmp`** en Traefik, orquestador, extract,
  persistence y auditlog — filesystem raíz inmutable; solo `/tmp` es escribible.
- **Healthchecks** por servicio:
  - `traefik-public` / `traefik-internal`: `wget http://127.0.0.1:8080/ping` (entrypoint interno).
  - `orchestrator`: `wget http://127.0.0.1:8080/readyz` (readiness agregado; incluye dependencias).
  - `extract`: sin `HEALTHCHECK` de contenedor (runtime distroless sin shell).
    La salud la validan los healthchecks activos de Traefik (`/healthz`) en modo
    entorno y el check de Consul Catalog en modo Consul.
  - `persistence` / `auditlog`: `/health` (auditlog lo trae en su Dockerfile).
  - `mongo`: `mongosh --eval "db.adminCommand('ping').ok"`.

Verificación de que el host **no** alcanza los MS internos:

```bash
curl -sS --max-time 2 http://127.0.0.1:8080/ ; echo "exit=$?"   # conexión rechazada/000
```

---

## 11. Limitaciones conocidas y desvíos

### 10.1 El provider Docker no puede dar `503` para un contenedor *removido*

El provider Docker de Traefik solo descubre contenedores **presentes** y, además,
**excluye los que no están `healthy`** ([#7732](https://github.com/traefik/traefik/issues/7732)).
Comportamiento observado:

| Escenario del MS | Con `allowEmptyServices: true` | Con el default (`false`) |
| ---------------- | ------------------------------ | ------------------------ |
| **`docker compose stop <ms>`** (contenedor **removido**) | `404` (el servicio desaparece: no hay labels) | `404` |
| Contenedor **unhealthy** que *nunca* llegó a healthy | **`500`** (bug [#13261](https://github.com/traefik/traefik/issues/13261)), no el `503` documentado | `404` |
| Contenedor **pausado** (era healthy) | petición **cuelga** hasta el timeout | — |
| Contenedor **presente** con backend que **falla** | **`503`** vía circuit breaker ✅ | `503` |

**Conclusión:** con el provider Docker, "MS caído" en el sentido de *contenedor
eliminado* **siempre** da `404`, no `503` (limitación del provider, no del
breaker). El `503` garantizado sale del **circuit breaker** cuando el servidor
sigue presente pero responde mal. Por eso el criterio de aceptación se formula
como: *"un MS que falla **estando presente** ⇒ `503` (breaker)"*.

**Alternativas si se quisiera `503` aun con el contenedor removido** (no
adoptadas):

- Definir los servicios E-W **estáticos** en `dynamic.yml` (file provider) con
  URLs fijas: el servicio siempre existe ⇒ el breaker ⇒ `503`. Costo: se pierde
  el auto-descubrimiento de las 5 réplicas.
- Mapear en el orquestador un `404` del upstream E-W a `503`. Descartado: el
  `404` de persistence es **semántico** ("no encontrado"), no se puede mapear
  globalmente.

### 10.2 Otros desvíos

- **`allowEmptyServices` deja un `500`** mientras #13261 no se arregle (§4.3).
- **`tasks/plan.md` §12 decisión #5** nombra `http2.enabled: false`; la
  implementación usa `disableHTTP2: true` (campo correcto en v3.7) — §2.4.
- **`remote_addr` del access log del orquestador** es la IP del contenedor
  Traefik, no la del cliente; la IP real viaja en `X-Forwarded-For` (access log
  de Traefik, D12.3).
- **`k6`** (`scripts/k6/spike.js` del repo del validador) queda para los
  **compose locales** (verifica `checksum == SHA-256(bytes)` bajo carga); para el
  **borde** con rate limit se usa `vegeta` (si no, mide mayormente los `429`).

---

## 12. Solución de problemas

| Síntoma | Causa | Solución |
| ------- | ----- | -------- |
| `permission denied` leyendo `traefik-key.pem` | key en `600` y `cap_drop: ALL` (sin `DAC_OVERRIDE`) | `./certs/generate-certs.sh` (deja `644`) o `chmod 644 certs/*.pem certs/*.key` |
| `Could not find network named backend` | falta `network:` en el provider docker | ya fijado: `network: pdf-extractext_backend` |
| Backends devuelven `505 HTTP Version Not Supported` | Traefik intenta h2c contra backends cleartext | ya fijado: `serversTransport.default.disableHTTP2: true` |
| `x509: certificate signed by unknown authority` o `404` al llamar a `http://traefik-internal:8443` | el entrypoint interno ya no termina TLS para los routers E-W (Traefik responde con su cert autofirmado por defecto) | usar `http://traefik-internal:8443`; el TLS vive sólo en `:443`. Si persiste tras el cambio, hay una registración vieja en Consul con `tls=true`: recrear el servicio |
| `the service "X@docker" does not exist` **al arrancar** | un router referencia un service de OTRO provider (cruzado) | declarar el router en las labels del mismo servicio (ya es así en `compose.yaml`); ver §2.3 |
| El cliente recibe `502` en el primer request tras caerse un MS | Breaker todavía cerrado | es lo esperado; a partir del siguiente responde `503` |
| Consul deja un MS detenido como `passing`; logs `deregistration blocked by ACLs` / `anonymous token` | el agente quitó el servicio localmente pero no pudo actualizar el catálogo | desde el Consul externo: `./scripts/bootstrap-agent-acl.sh`; comprobar agente **y** catálogo, no limpiar sólo la UI |
| RPC interno con `x509 ... not server.dc-converter.consul` | el certificado no tiene el SAN del RPC interno | `./scripts/renew-server-cert.sh && docker compose restart consul` en el Consul externo; no desactivar `verify_server_hostname` |
| `docker compose up` falla pidiendo un token | falta `.env` con `*_API_TOKEN` | `cp .env.example .env` y completar |

---

## 13. Referencias

- Traefik — Docker provider y `allowEmptyServices`:
  <https://doc.traefik.io/traefik/providers/docker/#allowemptyservices>
- Issue #7732 (contenedores unhealthy se excluyen):
  <https://github.com/traefik/traefik/issues/7732>
- Issue #13261 (`allowEmptyServices` devuelve `500` en vez de `503`):
  <https://github.com/traefik/traefik/issues/13261>
- `serversTransport` / `disableHTTP2`:
  <https://doc.traefik.io/traefik/routing/services/#servers-transport>
- Código de la Fase 11 en el plan del validador:
  `validator/ValidationMicroservices-pdf-extractext/tasks/plan.md` §12 y
  `tasks/todo.md` (Tasks 53–59).
