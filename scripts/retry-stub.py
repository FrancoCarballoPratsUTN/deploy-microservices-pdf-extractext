#!/usr/bin/env python3
"""Stub HTTP de fallo intermitente para ejercitar los middlewares *retry* de
Traefik (deploy/traefik/dynamic.yml) sin depender de un microservicio real.

Devuelve `502 Bad Gateway` las primeras FAIL_TIMES peticiones de cada pareja
método/ruta y, a partir de ahí, `200 OK` con un cuerpo JSON mínimo. Cada
petición se imprime en stdout (`STUB <METODO> <path> attempt=N`) para poder
contar cuántas veces Traefik reintentó antes de rendirse.

Uso (se corre como contenedor efímero dentro de la red `backend`, con las
labels del servicio cuyo retry se quiere probar; ver scripts/verify-retries.sh):

    docker run --rm --network pdf-extractext_backend --no-healthcheck \\
      --label traefik.enable=true \\
      --label traefik.http.services.extract.loadbalancer.server.port=8080 \\
      -e FAIL_TIMES=2 -v "$PWD/scripts/retry-stub.py:/stub.py:ro" \\
      --entrypoint python3 python:3.14-slim /stub.py

Por qué un stub y no un MS real: un MS sano no devuelve `502` de forma
controlada. La única forma determinista de ver el retry en acción es un
backend que falle las primeras veces y luego responda.
"""

import http.server
import os

FAIL_TIMES = int(os.environ.get("FAIL_TIMES", "2"))
PORT = int(os.environ.get("PORT", "8080"))
counts: dict[tuple[str, str], int] = {}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _handle(self) -> None:
        request_key = (self.command, self.path.split("?", maxsplit=1)[0])
        attempt = counts.get(request_key, 0) + 1
        counts[request_key] = attempt
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        print(f"STUB {self.command} {self.path} attempt={attempt}", flush=True)
        if attempt <= FAIL_TIMES:
            body = b"stub upstream failure"
            self.send_response(502)
        else:
            body = b'{"checksum":"stub","page_count":1,"text":"stub"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = _handle

    def log_message(self, *args) -> None:  # silenciar el log por defecto
        pass


if __name__ == "__main__":
    print(f"STUB listening on :{PORT} FAIL_TIMES={FAIL_TIMES}", flush=True)
    http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
