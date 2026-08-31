#!/usr/bin/env bash
# Step 3 — The LLM leg alone. Binds a port, writes nothing.
# Any status forwarded back is a pass (a bare 401 from Anthropic included) — it
# proves the request went out through the gateway and came home. A 502 with
# zax_llm_proxy_error means the forward itself failed.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_broker

PORT=8788
note "3. LLM leg via --llm-proxy (binds 127.0.0.1:$PORT, writes nothing)"
hr

"$BROKER" --llm-proxy >/dev/null 2>&1 &
PROXY_PID=$!
trap 'kill "$PROXY_PID" 2>/dev/null || true' EXIT

# Wait for the port to come up (max ~10s).
for _ in $(seq 1 20); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
  sleep 0.5
done

note "GET /v1/models — any forwarded status is a pass"
URL="$(llm_proxy_url "$PORT" "/v1/models")" || die "could not build the proxy URL — see the warning above"
CODE="$(curl -sSk -o /dev/null -w '%{http_code}' "$URL" || echo "000")"
printf 'HTTP %s\n' "$CODE"

if [[ "$CODE" == "000" || "$CODE" == "502" ]]; then
  warn "no forwarded status ($CODE) — check the [llm] line:"
  grep -aE "\[llm\] (GET|POST) /v1/models|zax_llm_proxy_error" "$ZAX_LOG" 2>/dev/null | tail -3
else
  ok "forwarded HTTP $CODE — request traversed the gateway and returned"
  grep -aE "\[forward\].*/v1/models|\[llm\] (GET|POST) /v1/models" "$ZAX_LOG" 2>/dev/null | tail -3 || true
fi

hr
ok "step 3 complete"
