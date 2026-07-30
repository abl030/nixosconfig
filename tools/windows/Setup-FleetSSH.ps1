<#
================================================================================
 Setup-FleetSSH.ps1  --  authorise the homelab fleet key on a Windows box
================================================================================

 WHY THIS EXISTS
   The target box (the Idealpos machine, 192.168.100.67) has no usable account
   password, so there is no way to ssh/scp/SMB the key on from doc1 first. This
   script is run ONCE at the Windows console by a local Administrator. After it
   succeeds, doc1 logs in with the fleet key and this script is never needed
   again.

   sshd is ALREADY installed and running there (OpenSSH_for_Windows_10.0), and
   doc1 already reaches port 22 over the Cullen tailscale subnet route. The only
   missing piece is the key in the right file with the right ACL -- but every
   step below is written to be safe on a box where none of that is true either.

 WHAT IT DOES
   1. Makes sure the OpenSSH Server is installed, set to Automatic, and running.
   2. Opens TCP 22 inbound, scoped to LAN + tailnet (only if nothing already does).
   3. Installs the fleet public key into BOTH authorized-key locations Windows
      OpenSSH can consult, so it works either way:
        C:\ProgramData\ssh\administrators_authorized_keys   (admin accounts)
        <profile>\.ssh\authorized_keys                      (normal accounts)
   4. Repairs the file ACLs. This is the #1 reason Windows key auth silently
      fails: sshd REFUSES an authorized-keys file that anyone other than
      SYSTEM / Administrators (and, for the per-user file, the user) can write.
   5. Ensures `PubkeyAuthentication yes` in sshd_config, inserted BEFORE the
      first `Match` block -- anything appended after a Match belongs to that
      Match and silently does nothing. Another classic.
   6. SELF-TESTS end to end: generates a throwaway keypair, authorises it, does a
      real `ssh -i throwaway Idealpos@127.0.0.1 whoami`, then removes it again.
      If that passes, doc1's key will work too. If it fails you find out now,
      while you are still standing at the machine.

 USAGE  (elevated PowerShell -- it offers to re-launch itself if not)
     powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup-FleetSSH.ps1

   From the NAS share, if this box can reach it:
     powershell -NoProfile -ExecutionPolicy Bypass -File "\\192.168.1.2\data\Life\Setup-FleetSSH.ps1"

   If the box cannot reach the share: open Notepad, paste this whole file, save
   as Setup-FleetSSH.ps1, and run the command above against it. The script is
   fully self-contained -- it downloads nothing and needs no internet.

 OPTIONS
   -TargetUser <name>          Account to authorise. Default: Idealpos.
   -PublicKey  <string>        Override the embedded key.
   -AllowBlankPasswordAuth     ONLY if the self-test fails on a blank-password
                               account. See the warning where it is used.
   -HardenPasswordAuth         After a PASSING self-test, also set
                               `PasswordAuthentication no` (key-only).
   -AnyRemote                  Do not scope the firewall rule to LAN/tailnet.

 Written for the homelab fleet, 2026-07-30. Safe to re-run: every step is
 idempotent and existing authorised keys are preserved, never replaced.
================================================================================
#>

[CmdletBinding()]
param(
    [string] $TargetUser = 'Idealpos',
    [string] $PublicKey  = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDGR7mbMKs8alVN4K1ynvqT5K3KcXdeqlV77QQS0K1qy master-fleet-identity',
    [switch] $AllowBlankPasswordAuth,
    [switch] $HardenPasswordAuth,
    [switch] $AnyRemote
)

$ErrorActionPreference = 'Stop'

# Well-known SIDs, used instead of names throughout: "Administrators" and
# "SYSTEM" are localised, and name-based ACL code breaks on a non-English
# Windows install.
$SID_SYSTEM = 'S-1-5-18'
$SID_ADMINS = 'S-1-5-32-544'

$SshDataDir = Join-Path $env:ProgramData 'ssh'
$SshdConfig = Join-Path $SshDataDir 'sshd_config'
$AdminKeys  = Join-Path $SshDataDir 'administrators_authorized_keys'

$script:Warnings = @()

function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    [ok]   $m" -ForegroundColor Green }
function Write-Info { param($m) Write-Host "    [info] $m" -ForegroundColor Gray }
function Write-Warn { param($m) Write-Host "    [warn] $m" -ForegroundColor Yellow; $script:Warnings += $m }
function Write-Fail { param($m) Write-Host "    [FAIL] $m" -ForegroundColor Red }

# ---------------------------------------------------------------- elevation ---
$principal = New-Object Security.Principal.WindowsPrincipal(
                 [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if (-not $PSCommandPath) {
        Write-Fail "Not elevated, and this was pasted rather than run from a file."
        Write-Info "Save it as Setup-FleetSSH.ps1 and run:"
        Write-Info "  powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup-FleetSSH.ps1"
        exit 1
    }
    Write-Host "Not elevated. Re-launching as Administrator..." -ForegroundColor Yellow
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit',
                 '-File', "`"$PSCommandPath`"", '-TargetUser', "`"$TargetUser`"")
    if ($AllowBlankPasswordAuth) { $argList += '-AllowBlankPasswordAuth' }
    if ($HardenPasswordAuth)     { $argList += '-HardenPasswordAuth' }
    if ($AnyRemote)              { $argList += '-AnyRemote' }
    try   { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList }
    catch { Write-Fail "Could not elevate: $($_.Exception.Message)" ; exit 1 }
    exit 0
}

$keyParts = $PublicKey.Trim() -split '\s+'
Write-Host ""
Write-Host "  Fleet SSH key installer" -ForegroundColor White
Write-Host "  host : $env:COMPUTERNAME"
Write-Host "  user : $TargetUser"
Write-Host "  key  : $($keyParts[0]) ...$($keyParts[1][-12..-1] -join '') $(if ($keyParts.Count -ge 3) { $keyParts[2] })"

# ------------------------------------------------------- resolve the account ---
Write-Step "Resolving account '$TargetUser'"
try {
    $userSid = (New-Object Security.Principal.NTAccount($TargetUser)).Translate(
                   [Security.Principal.SecurityIdentifier])
} catch {
    Write-Fail "No such account: $TargetUser"
    Write-Info "Enabled local accounts on this box:"
    try { Get-LocalUser | Where-Object Enabled | ForEach-Object { Write-Info "  $($_.Name)" } } catch {}
    Write-Info "Re-run with:  -TargetUser <name>"
    exit 1
}
Write-Ok "SID $($userSid.Value)"

# Is the account a local Administrator? That decides which authorized-keys file
# sshd will actually read. Checked by SID for the same locale reason as above.
$isAdminAccount = $false
try {
    $isAdminAccount = [bool](Get-LocalGroupMember -SID $SID_ADMINS -ErrorAction Stop |
        Where-Object { $_.SID.Value -eq $userSid.Value })
} catch {
    # Get-LocalGroupMember chokes on orphaned/domain SIDs left in the group. Fall
    # back to the current process token when we are asking about ourselves.
    if ($TargetUser -eq $env:USERNAME) { $isAdminAccount = $true }
    else { Write-Warn "Could not enumerate Administrators; assuming '$TargetUser' is NOT an admin." }
}
Write-Ok ("Administrator: {0}" -f $(if ($isAdminAccount) { 'yes' } else { 'no' }))

# Profile path from the SID -- more reliable than guessing C:\Users\<name>.
$profilePath = $null
try {
    $profilePath = (Get-CimInstance Win32_UserProfile -Filter "SID='$($userSid.Value)'" `
                        -ErrorAction Stop).LocalPath
} catch {}
if (-not $profilePath) {
    $profilePath = Join-Path (Split-Path $env:USERPROFILE -Parent) $TargetUser
    Write-Warn "No profile registered for this SID; assuming $profilePath"
}
Write-Ok "Profile $profilePath"

# Blank password? Windows restricts blank-password accounts to console logon by
# default (LimitBlankPasswordUse), which can break the S4U network logon OpenSSH
# performs for public-key auth. Detected now, acted on only if the self-test fails.
$blankPassword = $false
try {
    $lu = Get-LocalUser -SID $userSid.Value -ErrorAction Stop
    if (-not $lu.PasswordRequired -and -not $lu.PasswordLastSet) { $blankPassword = $true }
} catch {}
if ($blankPassword) { Write-Info "Account appears to have no password set." }

# ------------------------------------------------------------ OpenSSH server ---
Write-Step "OpenSSH Server"
$sshdSvc = Get-Service -Name sshd -ErrorAction SilentlyContinue
if (-not $sshdSvc) {
    Write-Info "sshd not present; installing the OpenSSH Server capability..."
    try {
        foreach ($cap in @('OpenSSH.Server*','OpenSSH.Client*')) {
            Get-WindowsCapability -Online -Name $cap |
                Where-Object State -ne 'Installed' |
                ForEach-Object { Add-WindowsCapability -Online -Name $_.Name | Out-Null }
        }
        $sshdSvc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    } catch {
        Write-Fail "Could not install OpenSSH Server: $($_.Exception.Message)"
        Write-Info "Usually means no internet, or a WSUS policy blocking Features on Demand."
        Write-Info "Install manually from https://github.com/PowerShell/Win32-OpenSSH/releases"
        Write-Info "then re-run this script."
        exit 1
    }
}
if (-not $sshdSvc) { Write-Fail "sshd still not present after the install attempt."; exit 1 }

Set-Service -Name sshd -StartupType Automatic
if ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd }
Write-Ok "sshd is Running / Automatic"

# The first start is what creates C:\ProgramData\ssh and the host keys.
if (-not (Test-Path $SshDataDir)) { Write-Fail "$SshDataDir missing -- sshd has never started."; exit 1 }

# ----------------------------------------------------------------- firewall ---
Write-Step "Firewall (TCP 22 inbound)"
$existingRules = @(Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'OpenSSH|SSH' })
if ($existingRules.Count) {
    Write-Ok "Existing allow rule(s): $(($existingRules.DisplayName | Select-Object -Unique) -join ', ')"
} else {
    $ruleArgs = @{
        Name        = 'FleetSSH-In-TCP22'
        DisplayName = 'Fleet SSH (TCP 22 inbound)'
        Direction   = 'Inbound'; Action = 'Allow'
        Protocol    = 'TCP';     LocalPort = 22
        Profile     = 'Any'
    }
    # Default to LAN + tailnet CGNAT rather than Any. Tailscale subnet routers
    # SNAT by default, so traffic from doc1 arrives sourced from the subnet
    # router's own LAN address -- which is why the local /16 is what matters.
    if (-not $AnyRemote) { $ruleArgs.RemoteAddress = @('192.168.0.0/16','10.0.0.0/8','172.16.0.0/12','100.64.0.0/10') }
    New-NetFirewallRule @ruleArgs | Out-Null
    Write-Ok "Created 'Fleet SSH (TCP 22 inbound)'$(if (-not $AnyRemote) { ' scoped to LAN + tailnet' })"
}

# -------------------------------------------------------------- ACL helpers ---
function Set-KeyFileAcl {
    <#
      sshd's StrictModes rejects an authorized-keys file that a non-privileged
      account can write to. Rebuild the ACL: inheritance off, owner
      Administrators, and only the SIDs passed in.

      Done in two passes on purpose. RemoveAccessRule throws on INHERITED rules,
      so we first persist "inheritance protected, inherited ACEs dropped", then
      re-read -- at which point every remaining ACE is explicit and removable.
    #>
    param(
        [Parameter(Mandatory)] [string]   $Path,
        [Parameter(Mandatory)] [string[]] $AllowSids
    )
    $acl = Get-Acl -Path $Path
    $acl.SetAccessRuleProtection($true, $false)
    Set-Acl -Path $Path -AclObject $acl

    $acl = Get-Acl -Path $Path
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
    foreach ($sid in $AllowSids) {
        $id  = New-Object Security.Principal.SecurityIdentifier($sid)
        $ace = New-Object Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'Allow')
        $acl.AddAccessRule($ace)
    }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier($SID_ADMINS)))
    Set-Acl -Path $Path -AclObject $acl
}

function Get-KeyBody {
    # Compare "<type> <base64>" and ignore the trailing comment, so re-running
    # with a differently-commented copy of the same key stays idempotent.
    param([string] $Line)
    $p = $Line.Trim() -split '\s+'
    if ($p.Count -ge 2) { return "$($p[0]) $($p[1])" }
    return $null
}

function Read-KeyLines {
    # Read and strip any BOM. A UTF-8 BOM corrupts the FIRST key line and sshd
    # silently ignores it -- a very common "it just won't take my key".
    param([string] $Path)
    if (-not (Test-Path $Path)) { return @() }
    $raw = [IO.File]::ReadAllText($Path) -replace "^\uFEFF", ''
    return @($raw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
}

function Write-KeyLines {
    param([string] $Path, [string[]] $Lines)
    # UTF8Encoding($false) == no BOM. CRLF is fine; sshd accepts either.
    [IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"),
                            (New-Object Text.UTF8Encoding($false)))
}

function Add-AuthorizedKey {
    param(
        [Parameter(Mandatory)] [string]   $Path,
        [Parameter(Mandatory)] [string]   $Key,
        [Parameter(Mandatory)] [string[]] $AllowSids
    )
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # @(...) is load-bearing: a function returning a ONE-element array gets
    # unwrapped to a bare string, and `+=` would then concatenate the new key
    # onto the end of the existing line instead of appending a new one.
    $lines   = @(Read-KeyLines $Path)
    $wanted  = Get-KeyBody $Key
    $already = [bool](@($lines | Where-Object { (Get-KeyBody $_) -eq $wanted }).Count)
    if (-not $already) { $lines += $Key.Trim() }

    Write-KeyLines -Path $Path -Lines $lines
    Set-KeyFileAcl -Path $Path -AllowSids $AllowSids
    return $already
}

function Remove-AuthorizedKey {
    param([string] $Path, [string] $Key)
    if (-not (Test-Path $Path)) { return }
    $body = Get-KeyBody $Key
    Write-KeyLines -Path $Path -Lines @(Read-KeyLines $Path |
        Where-Object { (Get-KeyBody $_) -ne $body })
}

# ----------------------------------------------------------- install the key ---
Write-Step "Installing the fleet public key"
if ($PublicKey -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-\S+|sk-ssh-ed25519@openssh\.com)\s+\S+') {
    Write-Fail "That does not look like an OpenSSH public key."; exit 1
}

$userKeys = Join-Path $profilePath '.ssh\authorized_keys'

# Both files are written on purpose. Which one sshd consults depends on the
# `Match Group administrators` block in sshd_config; writing both means the key
# works whether or not that block is present and whether or not the account is
# an admin. Both end up locked down, so the extra file costs nothing.
if ($isAdminAccount) {
    $had = Add-AuthorizedKey -Path $AdminKeys -Key $PublicKey -AllowSids @($SID_SYSTEM, $SID_ADMINS)
    Write-Ok ("{0}  ({1})" -f $AdminKeys, $(if ($had) { 'already present' } else { 'KEY ADDED' }))
}
$had = Add-AuthorizedKey -Path $userKeys -Key $PublicKey -AllowSids @($SID_SYSTEM, $SID_ADMINS, $userSid.Value)
Write-Ok ("{0}  ({1})" -f $userKeys, $(if ($had) { 'already present' } else { 'KEY ADDED' }))

$sshdText      = if (Test-Path $SshdConfig) { [IO.File]::ReadAllText($SshdConfig) } else { '' }
$hasAdminMatch = $sshdText -match '(?im)^\s*Match\s+Group\s+administrators'
$effectiveFile = if ($isAdminAccount -and $hasAdminMatch) { $AdminKeys } else { $userKeys }
Write-Info "sshd will read: $effectiveFile"

# --------------------------------------------------------------- sshd_config ---
Write-Step "sshd_config"
function Set-SshdManagedBlock {
    param([Parameter(Mandatory)] [hashtable] $Options)

    $begin = '# BEGIN fleet-ssh (managed by Setup-FleetSSH.ps1)'
    $end   = '# END fleet-ssh'

    $lines = @()
    if (Test-Path $SshdConfig) {
        if (-not (Test-Path "$SshdConfig.fleet-backup")) {
            Copy-Item $SshdConfig "$SshdConfig.fleet-backup" -Force   # keep the ORIGINAL
        }
        $lines = @([IO.File]::ReadAllText($SshdConfig) -split "`r?`n")
    }

    # Drop any previous managed block so re-runs do not stack up.
    $out = @(); $inBlock = $false
    foreach ($l in $lines) {
        if ($l.Trim() -eq $begin) { $inBlock = $true;  continue }
        if ($l.Trim() -eq $end)   { $inBlock = $false; continue }
        if (-not $inBlock)        { $out += $l }
    }

    # Comment out conflicting directives already in the GLOBAL section, so our
    # value is the effective one instead of losing to an earlier occurrence.
    for ($i = 0; $i -lt $out.Count; $i++) {
        if ($out[$i] -match '(?i)^\s*Match\s') { break }   # global section ends here
        foreach ($k in $Options.Keys) {
            if ($out[$i] -match "(?i)^\s*$k\s+") { $out[$i] = "# (fleet-ssh superseded) $($out[$i])" }
        }
    }

    $block = @($begin) + @($Options.Keys | ForEach-Object { "$_ $($Options[$_])" }) + @($end, '')

    # CRITICAL: insert BEFORE the first `Match` line. Directives placed after a
    # Match block are scoped to that block, not global, and silently do nothing.
    $idx = -1
    for ($i = 0; $i -lt $out.Count; $i++) { if ($out[$i] -match '(?i)^\s*Match\s') { $idx = $i; break } }

    if     ($idx -lt 0) { $final = @($out) + $block }
    elseif ($idx -eq 0) { $final = $block + @($out) }
    else                { $final = @($out[0..($idx - 1)]) + $block + @($out[$idx..($out.Count - 1)]) }

    [IO.File]::WriteAllText($SshdConfig, (($final -join "`r`n").TrimEnd() + "`r`n"),
                            (New-Object Text.UTF8Encoding($false)))
}

Set-SshdManagedBlock -Options ([ordered]@{ 'PubkeyAuthentication' = 'yes' })
Restart-Service sshd
Write-Ok "PubkeyAuthentication yes  (original saved as sshd_config.fleet-backup)"

# ---------------------------------------------------------------- self-test ---
# Proves the whole chain with a real SSH login over loopback using a throwaway
# key. This is what catches the blank-password S4U problem, a bad ACL, or a
# mis-scoped sshd_config -- now, rather than after you have walked away.
Write-Step "Self-test: real key login over loopback"
$testBase = Join-Path $env:TEMP ("fleet-selftest-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$testPub  = $null
$testPass = $false
$testInconclusive = $false
$prevEAP  = $ErrorActionPreference
try {
    # ssh and ssh-keygen write notices to stderr. With $ErrorActionPreference =
    # 'Stop', PowerShell 5.1 promotes ANY native stderr line reaching the
    # pipeline into a TERMINATING error -- so a harmless "Permanently added
    # 127.0.0.1 to the list of known hosts" would abort the self-test and report
    # a working key as broken. Relax it for this block only; $LASTEXITCODE is
    # what we actually judge success on.
    $ErrorActionPreference = 'Continue'

    & ssh-keygen -t ed25519 -f $testBase -N '""' -q -C 'fleet-selftest' 2>&1 | Out-Null
    if (-not (Test-Path "$testBase.pub")) { throw "ssh-keygen produced no key" }
    $testPub = (Get-Content "$testBase.pub" -Raw).Trim()

    $sids = if ($effectiveFile -eq $AdminKeys) { @($SID_SYSTEM, $SID_ADMINS) }
            else { @($SID_SYSTEM, $SID_ADMINS, $userSid.Value) }
    [void](Add-AuthorizedKey -Path $effectiveFile -Key $testPub -AllowSids $sids)

    # Run the client via Start-Process with a HARD timeout rather than `& ssh`.
    # An ssh client spawned from certain contexts (notably a Session-0 service,
    # e.g. when this script is itself launched over SSH or from a scheduled task)
    # can block forever instead of returning. This script must never hang on the
    # machine you are standing at, so an unresponsive client is killed and
    # reported as INCONCLUSIVE -- never as a failure, and never as a hang.
    # -n points stdin at NUL so the client cannot wait to drain an inherited one.
    $soFile  = "$testBase.out"
    $seFile  = "$testBase.err"
    $sshArgs = @(
        '-n', '-i', $testBase,
        '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL',
        '-o', 'LogLevel=ERROR', '-o', 'ConnectTimeout=10',
        '-o', 'PreferredAuthentications=publickey',
        "$TargetUser@127.0.0.1", 'whoami'
    )
    $proc = Start-Process -FilePath 'ssh.exe' -ArgumentList $sshArgs -NoNewWindow -PassThru `
                          -RedirectStandardOutput $soFile -RedirectStandardError $seFile
    # Touching .Handle is load-bearing, not a no-op: it makes PowerShell cache
    # the native process handle. Without it, Start-Process -PassThru hands back
    # an object whose .ExitCode reads back EMPTY once the process ends, and the
    # check below would call a perfectly good key a failure.
    $null = $proc.Handle

    if ($proc.WaitForExit(30000)) {
        $so = if (Test-Path $soFile) { (Get-Content $soFile -Raw) } else { '' }
        $se = if (Test-Path $seFile) { (Get-Content $seFile -Raw) } else { '' }
        if ($proc.ExitCode -eq 0 -and "$so".Trim()) {
            $testPass = $true
            Write-Ok "Key authentication WORKS. Remote whoami: $("$so".Trim())"
        } elseif ("$se" -match 'Permission denied|publickey|Authentication failed') {
            # sshd actively rejected the key -- a real, actionable failure.
            Write-Fail "Key authentication was REFUSED (exit $($proc.ExitCode))."
            @("$se".Trim() -split "`r?`n" | Where-Object { $_.Trim() }) |
                Select-Object -First 8 | ForEach-Object { Write-Info "  $_" }
        } else {
            # Non-zero, but nothing that looks like a refusal (client quirk,
            # loopback oddity, ...). Do NOT claim the key is bad -- say so
            # honestly and let the doc1 check be the decider.
            $testInconclusive = $true
            Write-Warn "Self-test inconclusive (exit $($proc.ExitCode)) -- no sign of an actual refusal."
            @("$se".Trim() -split "`r?`n" | Where-Object { $_.Trim() }) |
                Select-Object -First 6 | ForEach-Object { Write-Info "  $_" }
            Write-Info "The key IS installed; verify from doc1 (command shown below)."
        }
    } else {
        try { $proc.Kill() } catch {}
        $testInconclusive = $true
        Write-Warn "Self-test timed out after 30s -- the local ssh client did not return."
        Write-Info "This is a quirk of the client, NOT proof the key is bad. The key IS installed;"
        Write-Info "verify from doc1 instead (command shown below)."
    }
    Remove-Item $soFile, $seFile -Force -ErrorAction SilentlyContinue
} catch {
    $testInconclusive = $true
    Write-Warn "Self-test could not run: $($_.Exception.Message)"
    Write-Info "The key is still installed -- verify from doc1 (command shown below)."
} finally {
    $ErrorActionPreference = $prevEAP
    # ALWAYS remove the throwaway key again, from both files.
    if ($testPub) {
        Remove-AuthorizedKey -Path $AdminKeys -Key $testPub
        Remove-AuthorizedKey -Path $userKeys  -Key $testPub
        Write-Info "Throwaway self-test key removed."
    }
    Remove-Item "$testBase", "$testBase.pub" -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------- blank-password fallback ----------
if (-not $testPass -and -not $testInconclusive -and $blankPassword -and -not $AllowBlankPasswordAuth) {
    Write-Step "Likely cause: blank password"
    Write-Host @"
    '$TargetUser' has no password. The Windows policy 'Limit local account use of
    blank passwords to console logon only' (LimitBlankPasswordUse=1) blocks the
    network-type logon OpenSSH performs for public-key auth.

    Two ways forward, best first:

      1. Give the account a password. Key auth will still never prompt for it,
         and nothing about the console login changes except that it has one:
             net user $TargetUser *
         ...then re-run this script.

      2. Re-run with -AllowBlankPasswordAuth. That sets LimitBlankPasswordUse=0,
         which permits blank-password accounts to be used for NETWORK logon
         machine-wide -- not just for SSH. On a box other machines can reach,
         that is a real weakening. Prefer option 1.
"@ -ForegroundColor Yellow
    $script:Warnings += "self-test failed; blank password is the likely cause"
}

if ($AllowBlankPasswordAuth) {
    Write-Step "Relaxing LimitBlankPasswordUse (explicitly requested)"
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' `
                     -Name 'LimitBlankPasswordUse' -Value 0 -Type DWord
    Write-Warn "LimitBlankPasswordUse=0 -- blank-password accounts may now be used for network logon."
    Write-Info "Revert: Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' LimitBlankPasswordUse 1"
    Write-Info "Now re-run this script WITHOUT the switch to re-test."
}

# ------------------------------------------------- optional hardening ---------
if ($HardenPasswordAuth) {
    if ($testPass) {
        Set-SshdManagedBlock -Options ([ordered]@{
            'PubkeyAuthentication'   = 'yes'
            'PasswordAuthentication' = 'no'
        })
        Restart-Service sshd
        Write-Ok "PasswordAuthentication no (key-only)."
    } else {
        Write-Warn "Refusing to disable password auth: the self-test did not pass. That would lock you out."
    }
}

# ----------------------------------------------------------------- summary ----
Write-Step "Summary"
$ips = @()
try {
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
        Select-Object -ExpandProperty IPAddress)
} catch {}

Write-Host ""
Write-Host "  hostname : $env:COMPUTERNAME"
Write-Host "  user     : $TargetUser"
Write-Host "  addresses: $($ips -join ', ')"
Write-Host "  keyfile  : $effectiveFile"

$hostKey = Join-Path $SshDataDir 'ssh_host_ed25519_key.pub'
if (Test-Path $hostKey) {
    # Same native-stderr caveat as the self-test: never let a cosmetic
    # fingerprint lookup throw at the very end of a successful run.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $fp = (& ssh-keygen -lf $hostKey 2>&1 | Select-Object -First 1)
        Write-Host ""
        Write-Host "  host key fingerprint (doc1 should see this on first connect):"
        Write-Host "    $fp"
    } catch {} finally { $ErrorActionPreference = $prevEAP }
}

$addr = if ($ips.Count) { $ips[0] } else { $env:COMPUTERNAME }
Write-Host ""
if ($testPass) {
    Write-Host "  DONE and VERIFIED. From doc1:" -ForegroundColor Green
    Write-Host "    ssh $TargetUser@$addr" -ForegroundColor Green
} elseif ($testInconclusive) {
    Write-Host "  KEY INSTALLED, but not verified locally (the self-test could not run)." -ForegroundColor Yellow
    Write-Host "  Nothing is necessarily wrong. Confirm from doc1:" -ForegroundColor Yellow
    Write-Host "    ssh $TargetUser@$addr" -ForegroundColor Yellow
    Write-Host "  If that is refused, watch the sshd log here while doc1 retries:"
    Write-Host "    Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 30 | Format-List TimeCreated,Message"
} else {
    Write-Host "  NOT VERIFIED -- key authentication was actively REFUSED. See above." -ForegroundColor Red
    Write-Host "  Watch the sshd log while doc1 tries to connect:" -ForegroundColor Red
    Write-Host "    Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 30 | Format-List TimeCreated,Message"
}

if ($script:Warnings.Count) {
    Write-Host ""
    Write-Host "  Warnings raised:" -ForegroundColor Yellow
    $script:Warnings | ForEach-Object {
        Write-Host "    - $(($_ -split "`n" | Select-Object -First 1).Trim())" -ForegroundColor Yellow
    }
}
Write-Host ""
