# Fire the test call through the proxy, using the new https + per-install
# token scheme (token is the leading path segment; -k because it's our own
# freshly-minted local CA, not a system-trusted one).

$token = Get-Content "C:\Users\umesh\.ai-broker\llm-proxy.token" -Raw
$secureK = Read-Host "OpenAI key" -AsSecureString
$K = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($secureK))
curl.exe -k -sS "https://127.0.0.1:8788/$token/v1/responses" `
  -H "authorization: Bearer $K" -H "content-type: application/json" `
  -d '{\"model\":\"gpt-5.4-mini\",\"input\":\"pong\"}' -w "`n[http %{http_code}]`n"
Remove-Variable K, secureK
