<#
================================================================================
 Set-RdpSignedShortcut.ps1  --  stop the "Do you trust this remote connection?"
                                prompt on an RDP shortcut
================================================================================

 THE PROBLEM
   An unsigned .rdp file that enables local resource redirection (printers,
   clipboard, smart cards) makes the RDP client show:

       Do you trust this remote connection?
       [x] Printers   [ ] Clipboard   [ ] Smart cards
       [ ] Don't ask me again for connections to this computer

   Ticking "Don't ask me again" writes a BITMASK to
       HKCU\Software\Microsoft\Terminal Server Client\LocalDevices\<server>
   recording which redirections were approved. If the .rdp later asks for a
   redirection that is NOT in that mask, the prompt comes back -- every time.
   That is why a box can sit on e.g. 76 for years and still prompt for clipboard.

   For staff mid-service this is a modal dialog between them and the till.

 THE FIX
   Sign the .rdp with a code-signing certificate and tell the client to trust
   that publisher. The RDP client then trusts every setting inside the signature
   scope -- which includes RedirectClipboard, RedirectPrinters and
   RedirectSmartCards -- and stops asking. This is Microsoft's supported
   mechanism ("Specify SHA1 thumbprints of certificates representing trusted
   .rdp publishers"), not a workaround, and it survives profile resets.

 WHAT THIS DOES
   1. Creates (or reuses) a self-signed CODE SIGNING certificate.
   2. Backs up the .rdp, then signs it with rdpsign.exe.
   3. Installs the certificate's PUBLIC half into LocalMachine\TrustedPublisher
      and adds its SHA1 thumbprint to the trusted-.rdp-publishers policy.
   4. Optionally exports the public .cer so other terminals can trust the same
      publisher, and the .pfx so the same key can re-sign future .rdp files.
   5. Reports what it did and how to undo it.

 DELIBERATELY NOT DONE
   The certificate is NOT added to Trusted Root Certification Authorities. A cert
   in Root can vouch for ANY TLS certificate or signed code on that machine, so a
   leaked key would be a machine-wide problem. The thumbprint policy is the
   narrow, purpose-built mechanism, so we use only that.

   This also does NOT touch the terminal server, and does NOT change which host
   the shortcut connects to.

 USAGE  (elevated PowerShell on the CLIENT, i.e. the POS terminal)
   Sign a shortcut and trust it here, creating the publisher cert first time:
     powershell -NoProfile -ExecutionPolicy Bypass -File .\Set-RdpSignedShortcut.ps1 `
       -RdpPath 'C:\Users\Idealpos\Desktop\Server.rdp' -ExportDir 'C:\rdp-publisher'

   Trust the same publisher on ANOTHER terminal (no signing, no private key):
     powershell -NoProfile -ExecutionPolicy Bypass -File .\Set-RdpSignedShortcut.ps1 `
       -TrustOnly -CerPath '\\path\to\RdpPublisher.cer'

   On a box where Group Policy pins the execution policy, run it as an in-memory
   script block instead (execution policy does not apply):
     & ([scriptblock]::Create((Get-Content .\Set-RdpSignedShortcut.ps1 -Raw)))

 OPTIONS
   -RdpPath <path>      The .rdp to sign.
   -Subject <name>      Certificate subject. Default: CN=RDP Publisher.
   -ExportDir <dir>     Export the public .cer (and .pfx if -PfxPassword given).
   -PfxPassword <str>   Also export the private key, for re-signing later.
   -TrustOnly           Only install trust from -CerPath; do not sign anything.
   -CerPath <path>      Public certificate to trust (with -TrustOnly).
   -AlsoApproveDevices  Belt-and-braces: additionally set the LocalDevices mask
                        for this user so the prompt is suppressed even if the
                        signature path is not honoured. See the note where used.
   -Undo                Remove the trust and restore the .rdp from its backup.

 Written for the homelab fleet, 2026-07-30. Safe to re-run.
================================================================================
#>

[CmdletBinding()]
param(
    [string] $RdpPath,
    [string] $Subject   = 'CN=RDP Publisher',
    [string] $ExportDir,
    [string] $PfxPassword,
    [switch] $TrustOnly,
    [string] $CerPath,
    [switch] $AlsoApproveDevices,
    [switch] $Undo
)

$ErrorActionPreference = 'Stop'

$PolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$RdpSign   = Join-Path $env:SystemRoot 'System32\rdpsign.exe'

function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    [ok]   $m" -ForegroundColor Green }
function Write-Info { param($m) Write-Host "    [info] $m" -ForegroundColor Gray }
function Write-Warn { param($m) Write-Host "    [warn] $m" -ForegroundColor Yellow }
function Write-Fail { param($m) Write-Host "    [FAIL] $m" -ForegroundColor Red }

# ---------------------------------------------------------------- elevation ---
$principal = New-Object Security.Principal.WindowsPrincipal(
                 [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Fail "Must run elevated (it writes to LocalMachine cert stores and HKLM policy)."
    exit 1
}

# ------------------------------------------------------------------ helpers ---
function Add-TrustedThumbprint {
    <#
      The trusted-.rdp-publishers list is a comma-separated REG_SZ of SHA1
      thumbprints. Append rather than replace, so we never quietly revoke a
      publisher some other shortcut depends on.
    #>
    param([Parameter(Mandatory)][string] $Thumbprint)

    if (-not (Test-Path $PolicyKey)) { New-Item -Path $PolicyKey -Force | Out-Null }
    $current = (Get-ItemProperty -Path $PolicyKey -Name 'TrustedCertThumbprints' `
                    -ErrorAction SilentlyContinue).TrustedCertThumbprints
    $list = @()
    if ($current) { $list = @($current -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

    if ($list -contains $Thumbprint) {
        Write-Info "Thumbprint already listed in the trusted-publishers policy."
    } else {
        $list += $Thumbprint
        New-ItemProperty -Path $PolicyKey -Name 'TrustedCertThumbprints' `
                         -Value ($list -join ',') -PropertyType String -Force | Out-Null
        Write-Ok "Added thumbprint to the trusted-.rdp-publishers policy."
    }

    # Without this, the client may still prompt for a signed file from a
    # publisher it does not recognise as "allowed". 1 = allow signed .rdp from
    # publishers on the trusted list.
    New-ItemProperty -Path $PolicyKey -Name 'AllowSignedFiles' `
                     -Value 1 -PropertyType DWord -Force | Out-Null
}

function Import-ToStore {
    param([Parameter(Mandatory)][string] $Path,
          [Parameter(Mandatory)][string] $StoreName)
    $cert  = [Security.Cryptography.X509Certificates.X509Certificate2]::new($Path)
    $store = New-Object Security.Cryptography.X509Certificates.X509Store($StoreName, 'LocalMachine')
    $store.Open('ReadWrite')
    $existing = $store.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
    if (-not $existing) { $store.Add($cert) }
    $store.Close()
    return $cert
}

# --------------------------------------------------------------------- undo ---
if ($Undo) {
    Write-Step "Undo"
    if ($RdpPath -and (Test-Path "$RdpPath.unsigned-backup")) {
        Copy-Item "$RdpPath.unsigned-backup" $RdpPath -Force
        Write-Ok "Restored the original unsigned .rdp."
    } else {
        Write-Info "No .rdp backup to restore (pass -RdpPath to restore one)."
    }
    Remove-ItemProperty -Path $PolicyKey -Name 'TrustedCertThumbprints' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $PolicyKey -Name 'AllowSignedFiles'       -ErrorAction SilentlyContinue
    Write-Ok "Cleared the trusted-publishers policy values."
    Write-Info "Certificates in LocalMachine\TrustedPublisher were left alone; remove by thumbprint if wanted."
    exit 0
}

# --------------------------------------------------------------- trust only ---
if ($TrustOnly) {
    Write-Step "Trust an existing publisher certificate"
    if (-not $CerPath -or -not (Test-Path $CerPath)) { Write-Fail "-TrustOnly needs a valid -CerPath."; exit 1 }
    $cert = Import-ToStore -Path $CerPath -StoreName 'TrustedPublisher'
    Write-Ok "Imported $($cert.Subject) into LocalMachine\TrustedPublisher."
    Add-TrustedThumbprint -Thumbprint $cert.Thumbprint
    Write-Ok "Done. SHA1 $($cert.Thumbprint)"
    exit 0
}

# ------------------------------------------------------------- sanity check ---
if (-not $RdpPath)            { Write-Fail "Pass -RdpPath (or use -TrustOnly / -Undo)."; exit 1 }
if (-not (Test-Path $RdpPath)) { Write-Fail "No such file: $RdpPath"; exit 1 }
if (-not (Test-Path $RdpSign)) { Write-Fail "rdpsign.exe not found at $RdpSign"; exit 1 }

Write-Host ""
Write-Host "  RDP shortcut signer" -ForegroundColor White
Write-Host "  host : $env:COMPUTERNAME"
Write-Host "  file : $RdpPath"

# ------------------------------------------------------- certificate ----------
Write-Step "Publisher certificate"
$cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -eq $Subject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) } |
    Sort-Object NotAfter -Descending | Select-Object -First 1

if ($cert) {
    Write-Ok "Reusing existing certificate (expires $($cert.NotAfter.ToString('yyyy-MM-dd')))."
} else {
    # 10 years: this is a private publisher identity for our own .rdp files, not
    # a public trust anchor. A short lifetime would just mean re-signing every
    # shortcut on every terminal at an arbitrary future date, mid-service.
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $Subject `
                -KeyUsage DigitalSignature -KeyLength 2048 `
                -CertStoreLocation 'Cert:\LocalMachine\My' `
                -NotAfter (Get-Date).AddYears(10)
    Write-Ok "Created certificate, valid to $($cert.NotAfter.ToString('yyyy-MM-dd'))."
}
Write-Info "Subject : $($cert.Subject)"
Write-Info "SHA1    : $($cert.Thumbprint)"

# ------------------------------------------------------------------ signing ---
Write-Step "Signing the shortcut"
if (-not (Test-Path "$RdpPath.unsigned-backup")) {
    Copy-Item $RdpPath "$RdpPath.unsigned-backup" -Force
    Write-Ok "Backed up the original to $(Split-Path $RdpPath -Leaf).unsigned-backup"
} else {
    Write-Info "Original backup already exists; left as-is."
}

# rdpsign's /sha256 selects the SIGNATURE hash algorithm. The argument that
# follows is the certificate's ordinary SHA1 thumbprint, not a SHA256 one --
# verified against a live rdpsign.exe, because the flag name invites the
# opposite assumption.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$signOut = & $RdpSign /sha256 $cert.Thumbprint /q $RdpPath 2>&1
$signRc  = $LASTEXITCODE
$ErrorActionPreference = $prevEAP

if ($signRc -ne 0) {
    Write-Fail "rdpsign failed (exit $signRc)."
    @($signOut) | ForEach-Object { Write-Info "  $_" }
    Write-Info "Restoring the original file."
    Copy-Item "$RdpPath.unsigned-backup" $RdpPath -Force
    exit 1
}

$text = Get-Content $RdpPath -Raw
if ($text -notmatch 'signature:') {
    Write-Fail "rdpsign reported success but the file carries no signature. Restoring."
    Copy-Item "$RdpPath.unsigned-backup" $RdpPath -Force
    exit 1
}
Write-Ok "Signed."
if ($text -match 'signscope:s:(.*)') {
    Write-Info "Signed settings: $($Matches[1].Trim())"
}

# ------------------------------------------------------------------- trust ----
Write-Step "Trusting the publisher on this machine"
$store = New-Object Security.Cryptography.X509Certificates.X509Store('TrustedPublisher','LocalMachine')
$store.Open('ReadWrite')
if (-not ($store.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint })) {
    # Public half only -- never put the private key in a trust store.
    # ::new() rather than New-Object: New-Object UNROLLS a byte[] into one
    # argument per byte ("no overload for ... argument count: 782"), so the
    # constructor never sees it as a single DER blob.
    $pub = [Security.Cryptography.X509Certificates.X509Certificate2]::new($cert.Export('Cert'))
    $store.Add($pub)
    Write-Ok "Imported the public certificate into LocalMachine\TrustedPublisher."
} else {
    Write-Info "Already present in LocalMachine\TrustedPublisher."
}
$store.Close()
Add-TrustedThumbprint -Thumbprint $cert.Thumbprint

# --------------------------------------------------- optional device belt -----
if ($AlsoApproveDevices) {
    # Independent of signing: pre-approve the redirections this .rdp asks for,
    # the same way ticking "Don't ask me again" would. Useful as a belt while
    # confirming the signature path works, and harmless afterwards. Per-user, so
    # it applies to whoever is logged in when this runs.
    Write-Step "Pre-approving redirected devices for the current user"
    if ($text -match '(?im)^\s*full address:s:(.+)$') {
        $server = $Matches[1].Trim()
        $ld = 'HKCU:\Software\Microsoft\Terminal Server Client\LocalDevices'
        if (-not (Test-Path $ld)) { New-Item -Path $ld -Force | Out-Null }
        $before = (Get-ItemProperty -Path $ld -Name $server -ErrorAction SilentlyContinue).$server
        New-ItemProperty -Path $ld -Name $server -Value 255 -PropertyType DWord -Force | Out-Null
        Write-Ok "LocalDevices\$server : $before -> 255 (all redirections this file requests)"
        Write-Info "Undo with: Remove-ItemProperty '$ld' -Name '$server'"
    } else {
        Write-Warn "Could not read 'full address' from the .rdp; skipped."
    }
}

# ------------------------------------------------------------------ export ----
if ($ExportDir) {
    Write-Step "Exporting the publisher certificate"
    if (-not (Test-Path $ExportDir)) { New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null }
    $cerOut = Join-Path $ExportDir 'RdpPublisher.cer'
    [IO.File]::WriteAllBytes($cerOut, $cert.Export('Cert'))
    Write-Ok "Public certificate -> $cerOut"
    Write-Info "Trust it on another terminal with:  -TrustOnly -CerPath '$cerOut'"

    if ($PfxPassword) {
        $pfxOut = Join-Path $ExportDir 'RdpPublisher.pfx'
        $sec = ConvertTo-SecureString -String $PfxPassword -AsPlainText -Force
        Export-PfxCertificate -Cert "Cert:\LocalMachine\My\$($cert.Thumbprint)" `
                              -FilePath $pfxOut -Password $sec | Out-Null
        Write-Ok "PRIVATE key -> $pfxOut"
        Write-Warn "That .pfx can sign .rdp files as this publisher. Move it somewhere safe"
        Write-Warn "(sops on doc1) and delete it from this machine."
    }
}

# ----------------------------------------------------------------- summary ----
Write-Step "Summary"
Write-Host ""
Write-Host "  Signed   : $RdpPath"
Write-Host "  Backup   : $RdpPath.unsigned-backup"
Write-Host "  Publisher: $($cert.Subject)"
Write-Host "  SHA1     : $($cert.Thumbprint)"
Write-Host ""
Write-Host "  Test it: double-click the shortcut and log in." -ForegroundColor Green
Write-Host "  The 'Do you trust this remote connection?' box should not appear." -ForegroundColor Green
Write-Host ""
Write-Host "  Note: this does NOT address a separate 'identity of the remote computer"
Write-Host "  cannot be verified' warning, which comes from the server's own certificate."
Write-Host ""
Write-Host "  Undo everything:" -ForegroundColor Gray
Write-Host "    .\Set-RdpSignedShortcut.ps1 -Undo -RdpPath '$RdpPath'" -ForegroundColor Gray
Write-Host ""
