#!/usr/bin/env bash
# verify-llm-gateway.sh — end-to-end verification of the LLM leg THROUGH the ZAX
# gateway (Optimus), for a specific provider. This is step3's bigger sibling:
# step3-llm-proxy.sh proves "any forwarded status came home"; this proves the
# request reaches the real provider and — with a key — returns a real 200.
#
# Verified working 2026-08-13 (OpenAI /v1/responses, gpt-5.4-mini → HTTP 200).
# See ../docs/ai-broker-work/ai-broker-design.html §"Live verification & test log".
#
#   ./verify-llm-gateway.sh                 # no-key probe only (expects a provider auth error)
#   OPENAI_API_KEY=sk-… ./verify-llm-gateway.sh   # also runs a keyed probe (expects 200)
#
# Knobs (env):
#   UPSTREAM      provider origin        (default https://api.openai.com)
#   PORT          local proxy bind port  (default 8789)
#   GATEWAY_HOST  host to cert-check     (default gateway.zsagenticdev.ai)
#   PROBE_PATH    keyed-probe endpoint   (default /v1/responses)
#   PROBE_BODY    keyed-probe JSON body  (default a gpt-5.4-mini haiku)
#   OPENAI_API_KEY  provider key for the keyed probe (from the ENVIRONMENT only —
#                   the script never puts it in argv/ps, never prints it)
#
# ── The one prerequisite that bites: SHUT OFF ZCC ──────────────────────────
# Zscaler Client Connector TLS-intercepts the gateway host and serves a synthetic
# deny cert, so the broker's HTTPS client fails and you get a misleading 502 (or an
# HTTP 403 block page) whether or not the broker works. This script refuses to run
# if it detects that interception. Stop ZCC — or allow-list the gateway host — first.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_broker

UPSTREAM="${UPSTREAM:-https://api.openai.com}"
PORT="${PORT:-8789}"
GATEWAY_HOST="${GATEWAY_HOST:-gateway.zsagenticdev.ai}"
PROBE_PATH="${PROBE_PATH:-/v1/responses}"
PROBE_BODY="${PROBE_BODY:-{\"model\":\"gpt-5.4-mini\",\"input\":\"write a haiku about ai\",\"store\":true}}"

note "LLM-leg e2e via the gateway  (upstream=$UPSTREAM  port=$PORT)"
hr

# ── 1. ZCC preflight — is the gateway host being TLS-intercepted? ───────────
note "1. preflight: checking $GATEWAY_HOST is not TLS-intercepted by ZCC"
if command -v openssl >/dev/null 2>&1; then
  ISSUER="$(echo | openssl s_client -connect "$GATEWAY_HOST:443" -servername "$GATEWAY_HOST" 2>/dev/null \
            | openssl x509 -noout -issuer 2>/dev/null || true)"
  if [[ "$ISSUER" == *"Bad Server Certificate"* ]]; then
    die "ZCC is intercepting $GATEWAY_HOST (issuer: $ISSUER).
       Stop Zscaler Client Connector (or allow-list the gateway host) and re-run.
       Expected issuer when clear: CN=Zscaler Agentic Root CA"
  elif [[ -z "$ISSUER" ]]; then
    warn "could not read $GATEWAY_HOST cert (offline / DNS?) — continuing, but the forward may fail"
  else
    ok "gateway cert issuer: ${ISSUER#issuer=}"
  fi
else
  warn "openssl not found — skipping the ZCC preflight (stop ZCC yourself before trusting a 502)"
fi

# ── 2. Start the LLM proxy (may trigger an interactive OIDC browser login) ──
note "2. starting --llm-proxy (a stale cached JWT opens a browser — complete the login)"
"$BROKER" --llm-proxy --upstream "$UPSTREAM" --port "$PORT" >/dev/null 2>&1 &
PROXY_PID=$!
trap 'kill "$PROXY_PID" 2>/dev/null || true' EXIT

# Wait up to ~180s for "proxy listening" (long, to allow the human OIDC step).
# The proxy writes its access token (ZAX_LLM_TOKEN_FILE) before it starts
# listening, so gate on the log line + port + token file all three.
LISTENING=""
for _ in $(seq 1 90); do
  if grep -aq "proxy listening on https://127.0.0.1:$PORT" "$ZAX_LOG" 2>/dev/null \
     && nc -z 127.0.0.1 "$PORT" 2>/dev/null \
     && [[ -s "$ZAX_LLM_TOKEN_FILE" ]]; then LISTENING=1; break; fi
  kill -0 "$PROXY_PID" 2>/dev/null || die "proxy exited before listening — see $ZAX_LOG"
  sleep 2
done
[[ -n "$LISTENING" ]] || die "proxy did not come up on :$PORT within ~180s — see $ZAX_LOG"
ok "proxy listening on 127.0.0.1:$PORT"
PROXY_URL_BASE="$(llm_proxy_url "$PORT" "")" || die "proxy is listening but its token file never appeared — see $ZAX_LOG"
# The caps the token-exchange granted (empty is fine — it does NOT gate forwarding):
grep -aE "token exchange complete.*intersected_caps" "$ZAX_LOG" 2>/dev/null | tail -1 || true

# ── 3. No-key probe — proves the request reaches the provider through the gateway
note "3. no-key probe → expect a PROVIDER auth error (401), NOT a Zscaler block / 502"
CODE="$(curl -sSk -o /dev/null -w '%{http_code}' \
          -X POST "${PROXY_URL_BASE}/v1/chat/completions" \
          -H 'content-type: application/json' \
          -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"ping"}]}' || echo 000)"
printf 'HTTP %s\n' "$CODE"
case "$CODE" in
  000|502) die "forward failed ($CODE) — the request never reached the provider (ZCC still up? gateway down?).
       $(grep -aE '\[llm\].*zax_llm_proxy_error|\[forward\]' "$ZAX_LOG" 2>/dev/null | tail -2)" ;;
  *)       ok "reached the provider through the gateway (any HTTP status here proves the path)" ;;
esac

# ── 4. Keyed probe (only if a key is in the environment) → expect 200 ───────
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  note "4. keyed probe: POST $PROBE_PATH  (key from \$OPENAI_API_KEY, kept out of argv/logs)"
  # Pass the Authorization header via a 0600 curl config file so the key is never
  # in the process arg list (ps). printf is a shell builtin, so it never forks with
  # the key either. The file is removed immediately after.
  umask 077
  KEYCFG="$(mktemp)"
  printf 'header = "Authorization: Bearer %s"\n' "$OPENAI_API_KEY" > "$KEYCFG"
  BODYFILE="$(mktemp)"
  CODE="$(curl -sSk -o "$BODYFILE" -w '%{http_code}' \
            -X POST "${PROXY_URL_BASE}${PROBE_PATH}" \
            -H 'content-type: application/json' \
            -K "$KEYCFG" \
            -d "$PROBE_BODY" || echo 000)"
  rm -f "$KEYCFG"
  printf 'HTTP %s\n' "$CODE"
  case "$CODE" in
    200) ok "real completion through the gateway — LLM leg VERIFIED end-to-end"
         # show only the model's text, not the whole (possibly large) body
         grep -oE '"text"[[:space:]]*:[[:space:]]*"[^"]*"' "$BODYFILE" 2>/dev/null | head -1 || true ;;
    429) warn "HTTP 429 insufficient_quota — this is OpenAI BILLING on '$PROBE_PATH'/this model, not the broker.
       Try a model/endpoint your key is funded for (the path itself is proven by the no-key probe above)." ;;
    401|403) warn "HTTP $CODE — provider rejected the key (bad/again-intercepted?). Body:";
             head -c 300 "$BODYFILE" 2>/dev/null; echo ;;
    *)   warn "HTTP $CODE — unexpected. Body:"; head -c 300 "$BODYFILE" 2>/dev/null; echo ;;
  esac
  rm -f "$BODYFILE"
else
  warn "4. keyed probe SKIPPED — set OPENAI_API_KEY in the environment to run it (expects 200)"
fi

# ── 5. Evidence: the broker's own forward + status lines ────────────────────
hr
note "broker's view (forward target + status):"
grep -aE "\[forward\].*($PROBE_PATH|/v1/chat/completions)|\[llm\] (GET|POST) ($PROBE_PATH|/v1/chat/completions)" \
     "$ZAX_LOG" 2>/dev/null | tail -4 || true

hr
ok "verify-llm-gateway complete"
