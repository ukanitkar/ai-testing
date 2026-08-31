# Check both the daemon and broker processes together — confirms the
# split-privilege result end-to-end: daemon should be SYSTEM/session 0,
# broker should be the active console user/session (e.g. umesh/3).

Get-Process zscaler-ai-protect, ai-broker-mon -IncludeUserName -ErrorAction SilentlyContinue |
    Select-Object Id, ProcessName, UserName, SI
