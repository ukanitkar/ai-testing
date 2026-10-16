"""
mitmproxy addon: log a TLS fingerprint for EVERY ClientHello, including ones
that will later be rejected by the client for not trusting our cert.

tls_clienthello() fires as soon as we've parsed the ClientHello -- before we
even decide what leaf cert to mint -- so it captures connections regardless of
whether the client goes on to accept or reject our certificate. That's the
property this needs: correlate "which TLS stack" with "accepted or rejected"
for connections to the SAME host in the SAME run.

Logs one line per attempt: client port (to correlate with mitmdump's own
accept/reject log lines by timestamp+port), SNI, cipher-suite list, and
whether an ALPN extension offering h2 was present -- a cheap, real signal that
differs between Node's TLS stack (openssl, via Node's own cipher list) and
Chromium/BoringSSL (Electron's net stack), without needing a full JA3 library.
"""
import os
from mitmproxy import tls, ctx

# Overridable so a run doesn't have to happen from this exact directory.
LOG = os.environ.get("TLS_FINGERPRINT_LOG", "./tls_fingerprints.log")


def tls_clienthello(data: tls.ClientHelloData) -> None:
    hello = data.client_hello
    peer = data.context.client.peername
    port = peer[1] if peer else None
    ciphers = ",".join(f"{c:#06x}" for c in hello.cipher_suites)
    alpn = ",".join(p.decode("latin1", "replace") for p in hello.alpn_protocols) if hello.alpn_protocols else ""
    line = (
        f"port={port} sni={hello.sni} "
        f"n_ciphers={len(hello.cipher_suites)} ciphers={ciphers} "
        f"alpn={alpn}\n"
    )
    with open(LOG, "a") as f:
        f.write(line)
    ctx.log.info(f"[tls_fingerprint] {line.strip()}")
