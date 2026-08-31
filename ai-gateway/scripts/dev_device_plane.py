#!/usr/bin/env python3
"""Minimal **dev device-plane mock** for ai-protect (ai-warden).

Stands in for the real ai-platform device plane so a daemon run with
`--allow-unenrolled --storage http --server-url http://127.0.0.1:8080` receives a
tenant config that turns the **AI Broker** on — which is what makes the daemon
spawn `ai-broker-mon`. There is no local file for tenant settings; `ai_broker.enabled`
only arrives via `GET /endpoint/v1/config` → `settings.received`, so this mock is
the smallest thing that delivers it.

Stdlib only (no pip/venv) so it runs anywhere python3 does, including the Windows VM.

Contract (mirrors src/services/heartbeat.rs):
  POST /endpoint/v1/heartbeat  -> {ingested, config_version}      (bumped version → daemon fetches config)
  GET  /endpoint/v1/config     -> {version, settings, managed_configs}   (settings carries ai_broker)
  POST /endpoint/v1/events[/bulk], /telemetry, /files/*, /uploads/presign -> 200 stub
  GET  /health                 -> 200 "ok"
  everything else              -> 200 {} (permissive, logged)

Usage:
    python3 dev_device_plane.py                 # :8080, ai_broker enabled
    python3 dev_device_plane.py --port 9099
    AI_BROKER_ENABLED=0 python3 dev_device_plane.py   # serve it disabled (to test the off path)
    CONFIG_VERSION=2 AI_BROKER_ENABLED=0 python3 dev_device_plane.py   # push a NEW
                                                     # frame to a RUNNING daemon
                                                     # (see CONFIG_VERSION below)
    HEARTBEAT_INTERVAL_SECONDS=60 python3 dev_device_plane.py   # make the daemon
                                                     # notice settings changes in
                                                     # ~1 min instead of ~10
    CONFIG_VERSION=5 DELAYED_CONFIG_VERSION=6 DELAYED_CONFIG_VERSION_AFTER_SECONDS=150 \
        python3 dev_device_plane.py   # serve version 5 unchanged for the first
                                       # 150s (a race-free window for a human to
                                       # act -- e.g. log off -- with zero risk of
                                       # the switch landing before they're done),
                                       # then switch to 6 on its own, no further
                                       # command needed once this process is running

Then point the daemon at it:
    zscaler-ai-protect daemon --allow-unenrolled --storage http --server-url http://127.0.0.1:8080 --no-install-exts

NOTE: this only supplies the ai_broker toggle. On Windows the daemon still needs
the CreateProcessAsUser privilege drop (spawn_broker) for the broker to run as the
logged-in user rather than SYSTEM. See docs/ai-broker-work/ai-broker-integration.html.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_START = time.monotonic()

# Config version the mock advertises. The daemon holds 0 initially, sees this on
# the heartbeat, notices the mismatch, and fetches /config once. Keep it constant
# across a run so the daemon fetches exactly once.
#
# Override via env to push a NEW frame to an already-running daemon: it only
# re-fetches /config when the heartbeat advertises a version it does not already
# hold, so flipping AI_BROKER_ENABLED alone is invisible to a daemon that has
# already seen version 1. Restart the mock with a higher CONFIG_VERSION to make
# it look at the settings again -- that is what makes the enabled -> disabled
# TRANSITION testable, as opposed to only a fresh daemon start.
CONFIG_VERSION = int(os.environ.get("CONFIG_VERSION", "1"))

# Optional built-in delay before switching to a second version, entirely inside
# this process -- no external command needs to land after the switch, which
# matters for tests where nobody can reach the machine for a while (e.g. a
# logoff test): a human re-arming the version by hand races the daemon's own
# ~60s heartbeat cadence, and reaction time (read instructions, type, execute)
# routinely loses that race, silently no-opping the very frame the test needed.
# Baking the delay into the mock's own clock removes the race outright.
_DELAYED_VERSION = os.environ.get("DELAYED_CONFIG_VERSION", "").strip()
_DELAY_SECONDS = int(os.environ.get("DELAYED_CONFIG_VERSION_AFTER_SECONDS", "0") or 0)


def _effective_version() -> int:
    if _DELAYED_VERSION and _DELAY_SECONDS and (time.monotonic() - _START) >= _DELAY_SECONDS:
        return int(_DELAYED_VERSION)
    return CONFIG_VERSION


def _ai_broker_enabled() -> bool:
    v = os.environ.get("AI_BROKER_ENABLED", "1").strip().lower()
    return v not in ("0", "false", "no", "off", "")


def _config_body() -> dict:
    # `settings` is the object-valued tenant toggle set; the ai_broker.launch
    # subscriber reads settings.ai_broker.enabled. `managed_configs: {}` is the
    # authoritative "no managed configs" (safe — nothing to enforce).
    settings = {"ai_broker": {"enabled": _ai_broker_enabled()}}

    # Optional: shorten the daemon's heartbeat so settings changes are noticed
    # in ~a minute instead of the 600 s default. services::heartbeat adopts a
    # server-pushed cadence from its next iteration, and clamps to
    # [60, 21600] seconds (logging a warning outside that), so 60 is the
    # practical floor. Only emitted when the env var is set, so the default
    # payload is unchanged for every other test.
    hb = os.environ.get("HEARTBEAT_INTERVAL_SECONDS", "").strip()
    if hb:
        settings["heartbeat_interval_seconds"] = int(hb)

    return {
        "version": _effective_version(),
        "policy": None,
        "settings": settings,
        "managed_configs": {},
    }


def _heartbeat_body() -> dict:
    return {"ingested": True, "config_version": _effective_version()}


class Handler(BaseHTTPRequestHandler):
    server_version = "dev-device-plane/1.0"

    def log_message(self, fmt, *args):  # concise access log to stderr
        sys.stderr.write("[device-plane] %s - %s\n" % (self.address_string(), fmt % args))

    def _drain_body(self) -> bytes:
        n = int(self.headers.get("Content-Length", 0) or 0)
        return self.rfile.read(n) if n > 0 else b""

    def _json(self, obj: dict, code: int = 200) -> None:
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/health":
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif path == "/endpoint/v1/config":
            cfg = _config_body()
            self.log_message("GET /config -> ai_broker.enabled=%s (version %d)",
                             cfg["settings"]["ai_broker"]["enabled"], CONFIG_VERSION)
            self._json(cfg)
        else:
            self._json({})  # permissive: unknown GETs succeed empty

    def do_POST(self):  # noqa: N802
        self._drain_body()
        path = self.path.split("?", 1)[0]
        if path == "/endpoint/v1/heartbeat":
            self._json(_heartbeat_body())
        elif path == "/endpoint/v1/uploads/presign" or path.startswith("/endpoint/v1/files"):
            # Stub the file registry: report "not needed" so the daemon uploads nothing.
            self._json({"upload_url": None, "needed": False})
        else:
            # events, events/bulk, telemetry, enroll, anything else → accept.
            self._json({"ingested": True})


def main() -> int:
    ap = argparse.ArgumentParser(description="Dev device-plane mock for ai-protect")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--host", default="127.0.0.1")
    args = ap.parse_args()

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    enabled = _ai_broker_enabled()
    print(f"[device-plane] listening on http://{args.host}:{args.port} "
          f"(ai_broker.enabled={enabled}, config_version={CONFIG_VERSION})", file=sys.stderr)
    print(f"[device-plane] point the daemon at:  --server-url http://{args.host}:{args.port}", file=sys.stderr)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[device-plane] shutting down", file=sys.stderr)
        httpd.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
