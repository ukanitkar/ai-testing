# Phase A -- secure_file ACL spot-check. Read-only; disturbs nothing.
# Run as UMESH (not Administrator): the DACL grants only umesh, and a file's
# OWNER always holds READ_CONTROL implicitly regardless of DACL contents, so
# umesh is the identity guaranteed to be able to read these descriptors.
#
# What restrict_to_owner applies: D:P(A;;FA;;;<sid>) -- a PROTECTED DACL with
# exactly one ACE, Full Access to the SID of the process that wrote the file.
# It deliberately does NOT set the owner, so the Owner field independently
# reflects WHO CREATED the file (a second confirmation of the privilege drop).

$home_ = "C:\Users\umesh\.ai-broker"
$expectUser = "EC2AMAZ-VRAE5E8\umesh"

# Files that SHOULD carry the owner-only protected DACL.
$protected = @(
    "llm-proxy.token",      # llm_leg.rs load_or_create_token
    ".credentials.json",    # sidecar.rs cached JWT
    "mitm-ca-key.pem"       # mitm.rs write_private (the CA private key)
)
# Control: only the KEY goes through write_private, so the CERT should look
# normal (inherited ACEs). If this one also looks locked down, the directory
# itself is restrictive and the per-file tightening is not what we measured.
$control = "mitm-ca-cert.pem"

Write-Host "=== directory contents ===" -ForegroundColor Cyan
Get-ChildItem $home_ -Force | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize

$allPass = $true   # ABSENT (not created yet) doesn't fail this -- only an existing file with the wrong DACL does.

foreach ($f in $protected) {
    $p = Join-Path $home_ $f
    Write-Host ""
    Write-Host "=== $f ===" -ForegroundColor Cyan
    if (-not (Test-Path $p)) {
        Write-Host "  ABSENT -- skipping (not created yet on this host)" -ForegroundColor Yellow
        continue
    }

    $acl = Get-Acl $p
    $rules = @($acl.Access)

    # AreAccessRulesProtected is the direct read of
    # PROTECTED_DACL_SECURITY_INFORMATION: inheritance blocked.
    $isProtected = $acl.AreAccessRulesProtected
    $oneAce      = ($rules.Count -eq 1)
    $rightUser   = $oneAce -and ($rules[0].IdentityReference.Value -ieq $expectUser)
    $fullControl = $oneAce -and ($rules[0].FileSystemRights.ToString() -match "FullControl")
    $noInherited = -not ($rules | Where-Object { $_.IsInherited })

    Write-Host ("  owner              : {0}" -f $acl.Owner)
    Write-Host ("  ACE count          : {0}" -f $rules.Count)
    Write-Host ("  DACL protected     : {0}" -f $isProtected)
    Write-Host ("  no inherited ACEs  : {0}" -f $noInherited)
    foreach ($r in $rules) {
        Write-Host ("    - {0} : {1} (inherited={2})" -f $r.IdentityReference, $r.FileSystemRights, $r.IsInherited)
    }

    if ($isProtected -and $oneAce -and $rightUser -and $fullControl -and $noInherited) {
        Write-Host "  VERDICT: PASS -- owner-only protected DACL" -ForegroundColor Green
    } else {
        Write-Host "  VERDICT: FAIL -- see above" -ForegroundColor Red
        Write-Host "  NOTE: llm_leg/sidecar/mitm all call restrict_to_owner as" -ForegroundColor Yellow
        Write-Host "        'let _ = ...', discarding the Result, so a failure here" -ForegroundColor Yellow
        Write-Host "        is silent in the logs. That is why this check exists." -ForegroundColor Yellow
        $allPass = $false
    }

    if ($acl.Owner -ine $expectUser) {
        Write-Host ("  WARNING: owner is {0}, expected {1} -- something wrote this" -f $acl.Owner, $expectUser) -ForegroundColor Red
        Write-Host "           as the wrong identity (privilege-drop regression?)" -ForegroundColor Red
        $allPass = $false
    }
}

Write-Host ""
Write-Host "=== $control (CONTROL -- expected NOT locked) ===" -ForegroundColor Cyan
$cp = Join-Path $home_ $control
if (Test-Path $cp) {
    $cacl = Get-Acl $cp
    Write-Host ("  owner          : {0}" -f $cacl.Owner)
    Write-Host ("  DACL protected : {0}  (expect False)" -f $cacl.AreAccessRulesProtected)
    Write-Host ("  ACE count      : {0}  (expect >1)" -f @($cacl.Access).Count)
    foreach ($r in $cacl.Access) {
        Write-Host ("    - {0} : {1} (inherited={2})" -f $r.IdentityReference, $r.FileSystemRights, $r.IsInherited)
    }
} else {
    Write-Host "  ABSENT" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== raw icacls, for the record ===" -ForegroundColor Cyan
foreach ($f in ($protected + $control)) {
    $p = Join-Path $home_ $f
    if (Test-Path $p) { icacls $p }
}

if (-not $allPass) { exit 1 }
exit 0
