#!/usr/bin/env python3
"""Lightweight HTTP backend for throughput benchmarks.

Replaces kubectl port-forward which can't handle 1000+ concurrent connections.
Provides the same /health and /hash endpoints as the validation-server.
"""
import hashlib
import json
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler


class BenchHandler(BaseHTTPRequestHandler):
    """Minimal handler: /health returns OK, /hash returns SHA-256 of POST body."""

    def do_GET(self):
        if self.path == "/health":
            self._json_response({"status": "ok"})
        elif self.path.startswith("/echo"):
            headers = {k: v for k, v in self.headers.items()}
            self._json_response({
                "headers": headers,
                "host": self.headers.get("Host", ""),
                "method": "GET",
                "path": self.path,
                "request_id": self.headers.get("X-Request-ID", ""),
            })
        else:
            self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        if self.path == "/hash":
            sha = hashlib.sha256(body).hexdigest()
            self._json_response({"sha256": sha, "size": len(body)})
        else:
            self.send_error(404)

    def _json_response(self, data):
        body = json.dumps(data).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass  # silence request logging


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18080
    # Use ThreadingHTTPServer for concurrent requests
    from http.server import ThreadingHTTPServer
    server = ThreadingHTTPServer(("127.0.0.1", port), BenchHandler)
    print(f"Benchmark backend listening on 127.0.0.1:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
