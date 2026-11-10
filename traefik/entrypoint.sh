#!/bin/sh
# Genera la configuración estática de Traefik a partir de la plantilla y de las
# variables de bootstrap. El token de Consul no se guarda en la imagen ni en el
# repositorio: sólo existe en el entorno del contenedor y en el archivo temporal
# de /tmp (tmpfs).
set -eu

: "${CONSUL_CATALOG_ADDRESS:?CONSUL_CATALOG_ADDRESS is required}"
: "${CONSUL_TRAEFIK_TOKEN:?CONSUL_TRAEFIK_TOKEN is required}"

template=/etc/traefik/traefik.yml.template
target=/tmp/traefik.yml

# Escapa los caracteres que sed interpreta dentro del reemplazo. Los tokens
# suelen ser UUIDs, pero no se asume nada sobre su contenido.
sed_escape() {
    printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

catalog_address=$(sed_escape "$CONSUL_CATALOG_ADDRESS")
catalog_scheme=$(sed_escape "${CONSUL_CATALOG_SCHEME:-https}")
catalog_token=$(sed_escape "$CONSUL_TRAEFIK_TOKEN")
log_level=$(sed_escape "${LOG_LEVEL:-info}")

sed \
    -e "s|__CONSUL_CATALOG_ADDRESS__|${catalog_address}|g" \
    -e "s|__CONSUL_CATALOG_SCHEME__|${catalog_scheme}|g" \
    -e "s|__CONSUL_TRAEFIK_TOKEN__|${catalog_token}|g" \
    -e "s|__LOG_LEVEL__|${log_level}|g" \
    "$template" >"$target"

exec traefik --configFile="$target"
