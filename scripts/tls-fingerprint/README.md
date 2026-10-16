# TLS fingerprinting addon for CA-trust measurements

`mitmproxy_tls_fingerprint.py` is a `mitmproxy` addon used to isolate *which
internal component* of an agent is making a given TLS connection, when a
per-host accept/reject tally alone looks inconsistent (see
`agent-tls-and-ca-trust-matrix.md`'s `vscode-copilot` row, measured
2026-10-15).

## Why this, not just reading mitmdump's own accept/reject log

`mitmdump`'s own log tells you *whether* a connection was accepted or
rejected, but not *which HTTP stack inside the agent* made it. Two different
internal components hitting the same hostname can produce opposite trust
decisions, and from the outside that just looks like "sometimes it works" —
which is what a first pass at this measurement actually looked like.

The fix: hook `tls_clienthello`, which fires as soon as the ClientHello is
parsed — **before** mitmproxy even decides what leaf cert to mint, so it
captures every attempt regardless of whether the client goes on to accept or
reject that cert. Log the cipher-suite list and ALPN offer per attempt,
correlate by client port against the accept/reject outcome in mitmdump's own
log, and the TLS stack falls out:

- **A GREASE cipher value present** (`0x?A?A`, per RFC 8701 — e.g. `0xcaca`,
  `0xaaaa`) means **Chromium/BoringSSL** (Electron's `net`, a Chrome/Edge
  browser, etc.). Only Chromium emits GREASE values; this is a reliable,
  cheap signal, not a full JA3/JA4 fingerprint.
- **No GREASE value** means a non-Chromium stack — for a Node-based agent,
  this is Node's own OpenSSL-backed TLS. Different Node binaries/versions can
  still be told apart by cipher *count* and *order* (two distinct
  non-GREASE signatures showed up in the `vscode-copilot` run, consistent
  with VS Code's embedded Node and the separate `@github/copilot` agent-host
  child shipping their own Node runtimes).

## Usage

```bash
mitmdump --listen-port 8890 --set confdir=./mitm-conf \
  -s mitmproxy_tls_fingerprint.py
```

Set `TLS_FINGERPRINT_LOG=/path/to/file.log` to control where it writes;
defaults to `./tls_fingerprints.log`. Correlate against mitmdump's own
stdout/log by client port (both sides log `127.0.0.1:<port>`) and a
timestamp window — see the `vscode-copilot` row's measurement note for a
worked example of the correlation script.

## The one gotcha already hit

`ClientHello.alpn_protocols` is a list of **`bytes`**, not `str`. A bare
`",".join(hello.alpn_protocols)` raises `TypeError` inside the hook — and
because addon errors don't abort the connection, this fails **silently** for
every ClientHello that actually offers ALPN (which is most of them), while
connections with no ALPN offer at all log fine. That's exactly the kind of
partial, confusing failure that looks like a data problem rather than a code
bug — decode first: `p.decode("latin1", "replace")`.

## Compliance and cleanup, same as every CA-trust measurement

- Needs a non-IP / open-source workspace open in the agent before any
  relaunch — background discovery traffic can name the open workspace's repo
  even without an explicit chat prompt. See
  `vscode-copilot-enterprise-gate-account-test.md` §3's pilot-scope note.
- If run with `-w <file>.flows` (full flow capture), that file holds the
  real session's live bearer tokens in cleartext once TLS is terminated.
  This fingerprinting addon does not need `-w` — the text log it writes
  contains no request/response bodies and no credential values — so prefer
  running without it.
- Remove the CA from wherever it was trusted when done, and verify removal
  rather than assuming the delete command succeeded.
