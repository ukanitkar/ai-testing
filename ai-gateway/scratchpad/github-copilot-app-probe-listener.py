#!/usr/bin/env python3
"""Minimal HTTP listener for validating the GitHub Copilot app's BYOK forwarding.

Used to confirm that a `type='custom'` model_providers row's `base_url`
(see docs/github-copilot-app-interception-feasibility.md) is genuinely read
by the app's real inference call, not just accepted by the schema. Point a
registered "custom" provider's base_url at this listener, drive a real chat
in the app, and check the log / this process's stdout for the request.

Logs every request (method, path, headers, body) and answers with a
plausible-shaped, unambiguous response so the app's UI shows something
recognizable:
- GET  /models              -> a one-model OpenAI-style model list
- POST /chat/completions    -> a fixed placeholder chat completion
- POST /responses           -> the same placeholder in Responses-API shape
- anything else             -> 200 with an empty JSON body, still logged

Usage: python3 github-copilot-app-probe-listener.py [port] [log_path]
  port     defaults to 58090
  log_path defaults to probe_listener.log next to this script
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

DEFAULT_PORT = 58090
DEFAULT_LOG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "probe_listener.log")

PLACEHOLDER_TEXT = "Hello from the local test probe — this proves base_url is really used."


def log(log_path: str, line: str) -> None:
    stamped = f"{time.strftime('%Y-%m-%dT%H:%M:%S')} | {line}"
    print(stamped, flush=True)
    with open(log_path, "a") as f:
        f.write(stamped + "\n")


class Handler(BaseHTTPRequestHandler):
    log_path = DEFAULT_LOG_PATH

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length) if length else b""

    def _respond_json(self, obj: dict) -> None:
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _log_request(self, body: bytes) -> None:
        headers = "; ".join(f"{k}: {v}" for k, v in self.headers.items())
        log(self.log_path, f"{self.command} {self.path}")
        log(self.log_path, f"  headers: {headers}")
        if body:
            log(self.log_path, f"  body: {body.decode(errors='replace')[:2000]}")

    def do_GET(self):
        body = self._read_body()
        self._log_request(body)
        if self.path.rstrip("/").endswith("/models"):
            self._respond_json(
                {
                    "object": "list",
                    "data": [
                        {
                            "id": "test-model",
                            "object": "model",
                            "created": int(time.time()),
                            "owned_by": "local-test-probe",
                        }
                    ],
                }
            )
        else:
            self._respond_json({})

    def do_POST(self):
        body = self._read_body()
        self._log_request(body)
        if self.path.rstrip("/").endswith("/chat/completions"):
            self._respond_json(
                {
                    "id": "chatcmpl-local-test-probe",
                    "object": "chat.completion",
                    "created": int(time.time()),
                    "model": "test-model",
                    "choices": [
                        {
                            "index": 0,
                            "message": {
                                "role": "assistant",
                                "content": PLACEHOLDER_TEXT,
                            },
                            "finish_reason": "stop",
                        }
                    ],
                    "usage": {
                        "prompt_tokens": 10,
                        "completion_tokens": 12,
                        "total_tokens": 22,
                    },
                }
            )
        elif self.path.rstrip("/").endswith("/responses"):
            self._respond_json(
                {
                    "id": "resp-local-test-probe",
                    "object": "response",
                    "created": int(time.time()),
                    "model": "test-model",
                    "output": [
                        {
                            "type": "message",
                            "role": "assistant",
                            "content": [
                                {
                                    "type": "output_text",
                                    "text": PLACEHOLDER_TEXT,
                                }
                            ],
                        }
                    ],
                }
            )
        else:
            self._respond_json({})

    def log_message(self, fmt, *args):
        pass  # suppress default stderr access logging; we log ourselves


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PORT
    log_path = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_LOG_PATH
    Handler.log_path = log_path
    log(log_path, f"listening on 127.0.0.1:{port}")
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
