#!/usr/bin/env bash
#
# Genera el material TLS de desarrollo para el Traefik de deploy:
#   traefik.pem / traefik-key.pem  -> cert y key que sirve Traefik (borde :443)
#   rootCA.pem                     -> CA raíz de mkcert, para curl/tests del borde
#
# Uso: ./certs/generate-certs.sh
# Requiere: mkcert (https://github.com/FiloSottile/mkcert).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAROOT="$(mkcert -CAROOT)"

mkcert -install >/dev/null

mkcert \
  -cert-file "$SCRIPT_DIR/traefik.pem" \
  -key-file "$SCRIPT_DIR/traefik-key.pem" \
  pdf-extractext.localhost \
  '*.pdf-extractext.localhost' \
  traefik \
  localhost \
  127.0.0.1 \
  ::1 >/dev/null

cp "$CAROOT/rootCA.pem" "$SCRIPT_DIR/rootCA.pem"

# Traefik corre con cap_drop: ALL (sin DAC_OVERRIDE), así que no puede leer un
# key en modo 600 aunque sea root. Son certs de desarrollo: se dejan legibles.
chmod 644 "$SCRIPT_DIR/traefik-key.pem" "$SCRIPT_DIR/traefik.pem" "$SCRIPT_DIR/rootCA.pem"

echo "OK: certs listos en $SCRIPT_DIR"