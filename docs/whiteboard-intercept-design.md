# Whiteboard: Forwarding / Intercept design options

## Options considered

1. **System Level Proxy Settings**
2. **Network Level Interception (Routes)**
3. **Process Level Proxy Settings**
   - ~~Base URL change in settings.json~~ (ruled out)
   - HTTP_PROXY & HTTPS_PROXY env vars per process (e.g. Claude in settings.json)
   - Process-specific registry
4. **Kernel hook / Driver**
   1. Minimal kernel hook code in Rust — TCP connection opened / UDP stream opened → "socket open" event
   2. Figure out the process responsible
   3. From process, gather binary path & then metadata
   4. IPC or local proxy to send this info to listener
   5. Route the connection from step 1

## Protocol sequence to handle once intercepted (client C / server S)

```
C  <──── TCP/IP Connection ────>  S
   ──── HTTP Request/Response ──►
   ──── Upgrade to WSS ─────────►
   ◄──── 100 Continue ───────────
   ◄──── WSS Frame (Binary Format) ────►
```

Notes: the interception layer (option 3 or 4) needs to handle not just plain
HTTP but the HTTP→WSS upgrade handshake and subsequent binary WSS framing.
