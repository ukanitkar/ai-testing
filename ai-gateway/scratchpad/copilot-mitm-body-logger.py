from mitmproxy import http

LOG_PATH = "./mitm_bodies.log"

# The real model-catalog endpoint, confirmed live 2026-10-01:
# GET https://api.business.githubcopilot.com/models -> {"data": [...28 real models...]}
FAKE_EMPTY_MODELS_HOST = "api.business.githubcopilot.com"
FAKE_EMPTY_MODELS_PATH = "/models"


def _relevant(host: str) -> bool:
    return "github" in host


def request(flow: http.HTTPFlow) -> None:
    if (
        flow.request.pretty_host == FAKE_EMPTY_MODELS_HOST
        and flow.request.path.split("?")[0] == FAKE_EMPTY_MODELS_PATH
        and flow.request.method == "GET"
    ):
        flow.response = http.Response.make(
            200,
            b'{"data":[]}',
            {"Content-Type": "application/json"},
        )
        with open(LOG_PATH, "a") as f:
            f.write(f"\n*** FAKED empty model list for {flow.request.pretty_url} ***\n")
        return
    if not _relevant(flow.request.pretty_host):
        return
    with open(LOG_PATH, "a") as f:
        f.write(f"\n=== REQUEST {flow.request.method} {flow.request.pretty_url} ===\n")
        for k, v in flow.request.headers.items():
            f.write(f"  {k}: {v}\n")
        try:
            f.write(f"BODY: {flow.request.get_text()}\n")
        except Exception:
            f.write(f"BODY: <{len(flow.request.raw_content or b'')} raw bytes, not text>\n")


def response(flow: http.HTTPFlow) -> None:
    if not _relevant(flow.request.pretty_host):
        return
    with open(LOG_PATH, "a") as f:
        f.write(f"--- RESPONSE {flow.response.status_code} for {flow.request.pretty_url} ---\n")
        try:
            f.write(f"{flow.response.get_text()[:200000]}\n")
        except Exception:
            f.write("<non-text response>\n")


def websocket_message(flow: http.HTTPFlow) -> None:
    if not _relevant(flow.request.pretty_host):
        return
    msg = flow.websocket.messages[-1]
    direction = "C->S" if msg.from_client else "S->C"
    with open(LOG_PATH, "a") as f:
        f.write(f"\n~~~ WS {direction} on {flow.request.pretty_url} ~~~\n")
        if msg.is_text:
            f.write(f"{msg.text[:200000]}\n")
        else:
            f.write(f"<{len(msg.content)} binary bytes>\n")
