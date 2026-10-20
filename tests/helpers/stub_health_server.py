"""A stand-in for DIDSA-CAD's /health, for tests/server_probe.gd: 200 with the right X-API-Key, 401 with a wrong one, 403 for /forbidden,
500 for /broken, 404 elsewhere. Usage: python3 -I stub_health_server.py PORT KEY   (prints READY once it listens; stops after 60 s)."""
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
KEY = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            code = 200 if self.headers.get("X-API-Key") == KEY else 401
        elif self.path == "/forbidden/health":
            code = 403
        elif self.path == "/broken/health":
            code = 500
        else:
            code = 404
        body = b'{"status":"ok"}' if code == 200 else b'{"detail":"no"}'
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", PORT), Handler)
threading.Timer(60.0, server.shutdown).start()
print("READY", flush=True)
server.serve_forever()
