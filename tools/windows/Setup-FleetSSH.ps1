<#
================================================================================
 Setup-FleetSSH.ps1  --  give doc1 SSH access to a Windows box, in one paste
================================================================================

 WHAT IT IS
   A bootstrap tool for any Windows machine we need to work on. Run it once in an
   elevated PowerShell and doc1 can SSH in with the fleet key.

   It is built for the awkward cases, not the easy ones: a machine whose account
   has no usable password (so the key cannot be copied on first), a locked-down
   SKU where Group Policy silently overrides -ExecutionPolicy, an image where the
   OpenSSH feature cannot be installed at all, and boxes driven through an RMM or
   hypervisor guest agent rather than a keyboard.

 ACCESS IS TEMPORARY BY DESIGN
   sshd is left on Manual, not Automatic. It runs for THIS session and is gone
   after a reboot, so a machine you forget about closes itself. Re-running this
   re-opens it; -Persist keeps it across reboots.

   Close it deliberately when you are done:
     Stop-Service sshd -Force; Set-Service sshd -StartupType Disabled; `
       Get-NetFirewallRule -DisplayName '*SSH*' | Disable-NetFirewallRule

 USAGE  (ELEVATED PowerShell)
   Normally straight off the GitHub mirror, with nothing to download or save. It
   runs as an in-memory script block, which is not subject to execution policy or
   code signing. The Tls12 prefix is load-bearing: older Windows (.NET 4.6 era,
   e.g. LTSB 2016) still defaults to TLS 1.0 and cannot reach GitHub without it.

     [Net.ServicePointManager]::SecurityProtocol='Tls12'; iex (irm '<url>')

   Prefer a commit SHA over `master` in that URL where it matters that the
   content cannot change under you -- the wiki carries the current pinned form.
   To pass arguments, use the script-block form, because iex cannot take them:

     [Net.ServicePointManager]::SecurityProtocol='Tls12'; `
       & ([scriptblock]::Create((irm '<url>'))) -TargetUser bob -Persist

   From a local copy:
     powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup-FleetSSH.ps1

 WHAT IT DOES
   1. Installs the OpenSSH Server feature if it is missing. Where that is
      impossible -- routine on IoT / LTSB / WSUS-managed images, which either
      fail outright or hang forever against an unreachable Windows Update -- it
      gives up on a timer and prints exactly how to install the MSI by hand,
      having changed nothing.
   2. Opens TCP 22. Re-enables SSH rules a previous close disabled, and ALWAYS
      ensures its own port-keyed rule: a program-scoped rule pointing at an
      sshd.exe that has since moved enumerates perfectly and permits nothing.
   3. Authorises the fleet key, with correct ACLs, wherever applies:
        C:\ProgramData\ssh\administrators_authorized_keys   (administrators)
        <profile>\.ssh\authorized_keys                      (if a profile exists)
      Bad ACLs are the single commonest cause of silent key-auth failure: sshd
      refuses a key file writable by anyone but SYSTEM/Administrators (and, for
      the per-user file, the user).
   4. Ensures `PubkeyAuthentication yes`, inserted BEFORE the first `Match`
      block -- anything after a Match belongs to that block and silently does
      nothing.
   5. Starts sshd for this session.
   6. SELF-TESTS for real: generates a throwaway keypair, authorises it, performs
      an actual loopback SSH login, then removes it. You find out whether this
      worked while still standing at the machine, not after driving away.

   Idempotent. Existing authorised keys are preserved, never replaced, and the
   original sshd_config is kept at sshd_config.fleet-backup.

 OPTIONS
   -TargetUser <name>       Account to authorise. Defaults to the current user.
                            Under SYSTEM (scheduled task, RMM, guest agent) that
                            is the MACHINE account, so it falls back to the
                            console user, then to the sole enabled local account.
   -PublicKey <string>      Override the embedded fleet key.
   -Persist                 Leave sshd Automatic rather than session-only.
   -CapTimeoutSec <n>       Seconds to wait for the feature install before giving
                            up with manual instructions. Default 240.
   -HardenPasswordAuth      After a PASSING self-test, also set
                            `PasswordAuthentication no` (key-only). Refuses if
                            the self-test did not pass, so it cannot lock you out.
   -AllowBlankPasswordAuth  Only if the self-test is actively REFUSED on a
                            blank-password account. Relaxes LimitBlankPasswordUse
                            machine-wide -- see the warning where it is used.
   -AnyRemote               Do not scope the firewall rule to LAN + tailnet.

 Exit codes: 0 success, 1 error, 2 OpenSSH could not be installed (needs a human).

 Wiki: docs/wiki/infrastructure/windows-fleet-ssh-access.md
================================================================================
#>

[CmdletBinding()]
param(
    [string] $TargetUser = $env:USERNAME,
    [string] $PublicKey  = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDGR7mbMKs8alVN4K1ynvqT5K3KcXdeqlV77QQS0K1qy master-fleet-identity',
    [switch] $AllowBlankPasswordAuth,
    [switch] $HardenPasswordAuth,
    [switch] $AnyRemote,
    [switch] $Persist,
    [int]    $CapTimeoutSec = 240
)

$ErrorActionPreference = 'Stop'

# Well-known SIDs, used instead of names throughout: "Administrators" and
# "SYSTEM" are localised, and name-based ACL code breaks on a non-English
# Windows install.
$SID_SYSTEM = 'S-1-5-18'
$SID_ADMINS = 'S-1-5-32-544'

# Canonical location of this script, for the bootstrap one-liner echoed on failure.
$GHURL = 'https://raw.githubusercontent.com/abl030/nixosconfig/master/tools/windows/Setup-FleetSSH.ps1'

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
        # Running from memory (pasted, or fetched straight off GitHub), so there
        # is no file to hand to a re-launched elevated PowerShell. Tell the
        # operator how to get where they need to be instead of failing blankly.
        Write-Fail "Not elevated, and there is no script file to re-launch (running from memory)."
        Write-Info "Start PowerShell as Administrator, then paste the same one-liner again:"
        Write-Info ""
        Write-Info "  [Net.ServicePointManager]::SecurityProtocol='Tls12'; iex (irm '$GHURL')"
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

# ------------------------------------------------- resolve the target user ---
# $env:USERNAME is the MACHINE account ("HOST$") or SYSTEM when this runs from a
# SYSTEM context -- a scheduled task, an RMM agent, or a hypervisor guest agent.
# None of those is a login we can authorise, and those are exactly the paths you
# use to bootstrap a box you cannot reach interactively. Fall back to whoever is
# logged in at the console, then to the sole enabled local account. Only ever
# guess when the caller did not name a user explicitly.
if (-not $PSBoundParameters.ContainsKey('TargetUser')) {
    $isMachineCtx = $TargetUser -match '\$$' -or $TargetUser -in @('SYSTEM','LOCAL SERVICE','NETWORK SERVICE')
    if ($isMachineCtx) {
        $why = "running as '$TargetUser'"
        $console = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
        if ($console) {
            $TargetUser = ($console -split '\\')[-1]
            Write-Info "$why; targeting the console user '$TargetUser'."
        } else {
            $locals = @(Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.Enabled })
            if ($locals.Count -eq 1) {
                $TargetUser = $locals[0].Name
                Write-Info "$why; targeting the only enabled local account '$TargetUser'."
            } else {
                Write-Warn "$why and no console user is logged in. Pass -TargetUser explicitly."
            }
        }
    }
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

# Profile path from the SID. Deliberately NOT guessed if absent:
#   * under SYSTEM, $env:USERPROFILE is C:\Windows\system32\config\systemprofile,
#     so deriving a sibling path yields nonsense like
#     C:\Windows\system32\config\<user>;
#   * pre-creating C:\Users\<user> for an account that has never logged on makes
#     Windows create a DIFFERENT folder (<user>.<HOST>) at first logon, quietly
#     orphaning whatever we wrote.
# An account with no profile simply gets no per-user key file.
$profilePath = $null
try {
    $profilePath = (Get-CimInstance Win32_UserProfile -Filter "SID='$($userSid.Value)'" `
                        -ErrorAction Stop).LocalPath
} catch {}
$hasProfile = [bool]$profilePath
if ($hasProfile) {
    Write-Ok "Profile $profilePath"
} else {
    Write-Info "No profile yet (this account has never logged on) -- skipping the per-user key file."
}

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
function Show-ManualInstallHelp {
    <#
      Features on Demand is not available on every SKU. IoT / LTSB / Enterprise
      images behind WSUS routinely either throw or -- worse -- report success and
      install nothing at all. Both land here, because the only thing that matters
      is whether an sshd service exists afterwards.

      Do not try to be clever and download it: fetching and executing an
      installer for the operator is a much bigger supply-chain decision than
      fetching this script. Tell them exactly what to do and get out of the way.
    #>
    param([string] $Reason)

    Write-Host ""
    Write-Fail "Could not install OpenSSH Server automatically."
    if ($Reason) { Write-Info "Reason: $Reason" }
    Write-Host ""
    Write-Host "  Install it by hand, then re-run this script -- it will pick up from here." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1. On any machine, download the latest OpenSSH-Win64 MSI:" -ForegroundColor White
    Write-Host "       https://github.com/PowerShell/Win32-OpenSSH/releases/latest" -ForegroundColor Cyan
    Write-Host "       (grab OpenSSH-Win64-v<version>.msi -- the .msi is by far the easiest)"
    Write-Host ""
    Write-Host "  2. Copy it to this machine and install it (double-click, or):" -ForegroundColor White
    Write-Host "       msiexec /i OpenSSH-Win64-v<version>.msi ADDLOCAL=Server" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  3. Re-run the one-liner in an elevated PowerShell:" -ForegroundColor White
    Write-Host "       [Net.ServicePointManager]::SecurityProtocol='Tls12'; iex (irm '$GHURL')" -ForegroundColor Cyan
    Write-Host ""
    Write-Info "Nothing has been changed on this machine."
    Write-Info "If the feature install was merely slow it may still complete in the background;"
    Write-Info "re-running is always safe and will pick up an sshd that appeared since."
    Write-Host ""
}

$sshdSvc = Get-Service -Name sshd -ErrorAction SilentlyContinue
if (-not $sshdSvc) {
    Write-Info "sshd not present; trying the OpenSSH Server capability (up to ${CapTimeoutSec}s)..."
    $capError = $null
    # Run it in a job with a hard timeout. Features on Demand pulls from Windows
    # Update, so on a box with no route to WU this does not fail -- it HANGS,
    # indefinitely, with TiWorker spinning in the background. A hang at a
    # customer site is worse than an error, so bound it and fall through to the
    # manual-install instructions.
    $job = Start-Job -ScriptBlock {
        foreach ($cap in @('OpenSSH.Server*','OpenSSH.Client*')) {
            Get-WindowsCapability -Online -Name $cap -ErrorAction Stop |
                Where-Object State -ne 'Installed' |
                ForEach-Object { Add-WindowsCapability -Online -Name $_.Name -ErrorAction Stop | Out-Null }
        }
    }
    if (Wait-Job $job -Timeout $CapTimeoutSec) {
        $err = $null
        Receive-Job $job -ErrorVariable err 2>&1 | Out-Null
        if ($err) { $capError = ($err | Select-Object -First 1).ToString() }
    } else {
        Stop-Job $job -ErrorAction SilentlyContinue
        $capError = "timed out after ${CapTimeoutSec}s -- this box most likely has no route to Windows Update"
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    # Re-query REGARDLESS of whether the call threw. On some SKUs it reports
    # success and installs nothing, so the service is the only honest signal.
    $sshdSvc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $sshdSvc) {
        Show-ManualInstallHelp -Reason $(if ($capError) { $capError }
                                        else { "the capability reported success but no sshd service appeared (common on IoT / LTSB / WSUS-managed images)" })
        exit 2
    }
    Write-Ok "OpenSSH Server installed."
}

# Session-only by DEFAULT. This script's job is to open a door while we work,
# not to leave one standing open on someone else's machine. Manual means sshd
# runs now but does not come back after a reboot, so a forgotten box closes
# itself. -Persist opts into the old Automatic behaviour.
$startup = if ($Persist) { 'Automatic' } else { 'Manual' }
Set-Service -Name sshd -StartupType $startup
if ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd }
Write-Ok "sshd is Running / $startup$(if (-not $Persist) { '  (this session only -- gone after a reboot)' })"

# The first start is what creates C:\ProgramData\ssh and the host keys.
if (-not (Test-Path $SshDataDir)) { Write-Fail "$SshDataDir missing -- sshd has never started."; exit 1 }

# ----------------------------------------------------------------- firewall ---
Write-Step "Firewall (TCP 22 inbound)"
# Idempotently OPEN the port. Two distinct jobs:
#
#  1. Re-enable SSH rules that a previous "close" disabled, rather than stacking
#     a duplicate alongside them.
#  2. Guarantee our OWN port-based rule exists. A pre-existing rule whose name
#     matches /SSH/ is NOT proof the port is open: Windows firewall rules are
#     often PROGRAM-scoped, and a rule pointing at an sshd.exe that no longer
#     exists (e.g. the box previously had OpenSSH via Features on Demand and now
#     has it from the MSI, at a different path) enumerates perfectly and permits
#     nothing. Observed live: sshd Running, an enabled "OpenSSH SSH Server
#     Preview (sshd)" rule present, and port 22 still refusing connections.
#     A rule keyed on the PORT cannot go stale that way.
$sshRules = @(Get-NetFirewallRule -Direction Inbound -Action Allow -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'OpenSSH|SSH' })
$disabled = @($sshRules | Where-Object { $_.Enabled -ne 'True' -and $_.Enabled -ne $true })
if ($disabled.Count) {
    $disabled | Enable-NetFirewallRule
    Write-Ok "Re-enabled $($disabled.Count) disabled SSH rule(s): $(($disabled.DisplayName | Select-Object -Unique) -join ', ')"
}

$ourRule = Get-NetFirewallRule -Name 'FleetSSH-In-TCP22' -ErrorAction SilentlyContinue
if ($ourRule) {
    if ($ourRule.Enabled -ne 'True' -and $ourRule.Enabled -ne $true) { $ourRule | Enable-NetFirewallRule }
    Write-Ok "Port rule 'FleetSSH-In-TCP22' present and enabled."
} else {
    $ruleArgs = @{
        Name        = 'FleetSSH-In-TCP22'
        DisplayName = 'Fleet SSH (TCP 22 inbound)'
        Direction   = 'Inbound'; Action = 'Allow'
        Protocol    = 'TCP';     LocalPort = 22
        Profile     = 'Any'
    }
    # Tailscale subnet routers SNAT by default, so traffic from doc1 arrives
    # sourced from the subnet router's own LAN address -- hence the local /16.
    if (-not $AnyRemote) { $ruleArgs.RemoteAddress = @('192.168.0.0/16','10.0.0.0/8','172.16.0.0/12','100.64.0.0/10') }
    New-NetFirewallRule @ruleArgs | Out-Null
    Write-Ok "Created port rule 'Fleet SSH (TCP 22 inbound)'$(if (-not $AnyRemote) { ' scoped to LAN + tailnet' })"
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

$userKeys = if ($hasProfile) { Join-Path $profilePath '.ssh\authorized_keys' } else { $null }

# Both files are written on purpose. Which one sshd consults depends on the
# `Match Group administrators` block in sshd_config; writing both means the key
# works whether or not that block is present and whether or not the account is
# an admin. Both end up locked down, so the extra file costs nothing.
if ($isAdminAccount) {
    $had = Add-AuthorizedKey -Path $AdminKeys -Key $PublicKey -AllowSids @($SID_SYSTEM, $SID_ADMINS)
    Write-Ok ("{0}  ({1})" -f $AdminKeys, $(if ($had) { 'already present' } else { 'KEY ADDED' }))
}
if ($userKeys) {
    $had = Add-AuthorizedKey -Path $userKeys -Key $PublicKey -AllowSids @($SID_SYSTEM, $SID_ADMINS, $userSid.Value)
    Write-Ok ("{0}  ({1})" -f $userKeys, $(if ($had) { 'already present' } else { 'KEY ADDED' }))
} elseif (-not $isAdminAccount) {
    Write-Fail "'$TargetUser' is not an administrator and has no profile, so there is nowhere sshd will look for its key."
    Write-Info "Log in as '$TargetUser' once to create the profile, then re-run."
    exit 1
}

$sshdText      = if (Test-Path $SshdConfig) { [IO.File]::ReadAllText($SshdConfig) } else { '' }
$hasAdminMatch = $sshdText -match '(?im)^\s*Match\s+Group\s+administrators'
$effectiveFile = if ($isAdminAccount -and $hasAdminMatch) { $AdminKeys }
                 elseif ($userKeys)                        { $userKeys }
                 elseif ($isAdminAccount)                  { $AdminKeys }  # no profile: admins still have this
                 else                                      { $null }
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
        # $userKeys is $null for an account with no profile, and Test-Path on an
        # empty string throws -- which would abort the run in the finally block
        # AFTER a successful self-test, losing the summary and exiting non-zero.
        foreach ($f in @($AdminKeys, $userKeys)) {
            if ($f) { Remove-AuthorizedKey -Path $f -Key $testPub }
        }
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
