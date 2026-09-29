from mitmproxy import http

LOG_PATH = "./mitm_bodies.log"


def _relevant(host: str) -> bool:
    return "github" in host


def request(flow: http.HTTPFlow) -> None:
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
            f.write(f"{flow.response.get_text()[:2000]}\n")
        except Exception:
            f.write("<non-text response>\n")
