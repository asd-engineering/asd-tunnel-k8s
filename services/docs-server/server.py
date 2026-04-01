#!/usr/bin/env python3
"""Docs server for Docsify SPA.

Serves index.html and _sidebar.md from this directory.
All other paths (README.md, docs/*.md) are served from the project root.
"""

import os
import sys
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path

DOCS_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = Path(os.environ.get("PROJECT_ROOT", str(DOCS_DIR.parent.parent)))

LOCAL_FILES = {"index.html", "_sidebar.md"}


class DocsHandler(SimpleHTTPRequestHandler):
    def translate_path(self, path):
        # Strip query string and fragment
        path = path.split("?", 1)[0].split("#", 1)[0]
        # Normalize
        path = path.strip("/")

        if path in ("", "index.html", "_sidebar.md"):
            return str(DOCS_DIR / (path or "index.html"))

        return str(PROJECT_ROOT / path)

    def log_message(self, format, *args):
        sys.stderr.write(f"[docs] {args[0]}\n")


def main():
    port = int(os.environ.get("DOCS_PORT", "19080"))
    bind = os.environ.get("DOCS_BIND", "127.0.0.1")
    server = ThreadingHTTPServer((bind, port), DocsHandler)
    print(f"Docs server listening on http://{bind}:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()


if __name__ == "__main__":
    main()
