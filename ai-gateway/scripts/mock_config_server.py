"""Minimal local stand-in for ai-platform's /endpoint/v1/* used by
ai-protect's daemon mode. Point the daemon at it with:

    zscaler-ai-protect daemon --server-url http://localhost:8080 --allow-unenrolled

Serves exactly the two calls fetch_and_apply_config()/heartbeat need, with
the minimal field set confirmed against ai-protect's own structs
(HeartbeatResponse / ConfigResponse in src/services/heartbeat.rs) and the
ai_gateway tenant gate (src/subscribers/ai_broker_launch.rs).

Edit CONFIG_VERSION / SETTINGS below and just restart the server to push a
new tenant config on the daemon's next heartbeat.
"""

import json
from http.server import BaseHTTPRequestHandler, HTTPServer

CONFIG_VERSION = 1

# Minimal pair that makes tenant_is_usable() pass -- cloud + issuer.
# Edit to whatever tenant/cloud you're pointing this DVM run at.
SETTINGS = {
    "ai_gateway": {
        "cloud": "prod",
        "issuer": "https://aibroker-engineer.zslogin.net/",
    }
    # "ai_broker": {"enabled": True},  # optional -- absent already defaults true
}


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, obj, status=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path.startswith("/endpoint/v1/heartbeat"):
            length = int(self.headers.get("Content-Length", 0))
            self.rfile.read(length)  # drain the request body, ignored
            self._send_json({
                "ingested": True,
                "config_version": CONFIG_VERSION,
            })
        else:
            self._send_json({"error": "not found"}, status=404)

    def do_GET(self):
        if self.path.startswith("/endpoint/v1/config"):
            self._send_json({
                "version": CONFIG_VERSION,
                "settings": SETTINGS,
            })
        else:
            self._send_json({"error": "not found"}, status=404)

    def log_message(self, fmt, *args):
        print("[mock-config]", self.address_string(), fmt % args)


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 8080), Handler)
    print("serving on http://127.0.0.1:8080 (Ctrl-C to stop)")
    server.serve_forever()
