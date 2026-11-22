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
       netsh advfirewall firewall set rule name='Fleet SSH (TCP 22 inbound)' new enable=no

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
   1. Gets OpenSSH Server installed if it is missing, from Microsoft's official
      signed Win32-OpenSSH MSI (Authenticode signature verified before it runs).
      The Windows "optional feature" route is deliberately not used: in
      practice it hung against an unreachable Windows Update or installed
      nothing on most of our boxes, so the MSI ended up doing the job every
      time after a two-minute wait (#240). An sshd that is already installed,
      from either source, is used as-is. If the MSI cannot be fetched, it stops
      and prints manual instructions, having changed nothing.
   2. Opens TCP 22. Re-enables SSH rules a previous close disabled, and ALWAYS
      ensures its own port-keyed rule: a program-scoped rule pointing at an
      sshd.exe that has since moved enumerates perfectly and permits nothing.
   3. Authorises the fleet key, with correct ACLs, wherever applies:
        C:\ProgramData\ssh\administrators_authorized_keys   (administrators)
        <profile>\.ssh\authorized_keys                      (if a profile exists)
      Bad ACLs are the single commonest cause of silent key-auth failure: sshd
      refuses a key file writable by anyone but SYSTEM/Administrators (and, for
      the per-user file, the user).
   4. Configures sshd KEY-ONLY -- `PubkeyAuthentication yes`,
      `PasswordAuthentication no` -- inserted BEFORE the first `Match` block,
      since anything after a Match belongs to that block and silently does
      nothing. -AllowPasswordAuth opts out.
   5. Starts sshd for this session.
   6. SELF-TESTS for real: generates a throwaway keypair, authorises it, performs
      an actual loopback SSH login, then removes it. You find out whether this
      worked while still standing at the machine, not after driving away. On a
      failure it prints the relevant sshd log events itself.

 ENTRA ID (AZURE AD) ACCOUNTS
   Key-only SSH as a cloud-only Entra account cannot work on Win32-OpenSSH: the
   key is accepted, then the session closes as it opens, because sshd cannot
   build a logon token for an account with no password. So when the target is
   an Entra account (SID S-1-12-1-..., or AzureAD\name) the script creates a
   local administrator instead (default 'fleet', random password that is never
   shown or stored), authorises the key for that, and tells you to SSH as it.
   -NoLocalAdmin refuses instead; -LocalAdmin <name> picks the name, and also
   forces this mode for any other account sshd cannot log on (for example a
   domain account on a box that cannot reach its domain controller).

 THIRD-PARTY FIREWALLS
   OEM security suites (McAfee, Norton, ...) register their own firewall and
   drop inbound traffic regardless of Windows Firewall rules. The loopback
   self-test cannot see that. The script warns when one is registered, and the
   final check always has to come from doc1:  nc -vz -w5 <ip> 22
   A timeout means something is dropping packets; "refused" means nothing is
   listening.

   Idempotent. Existing authorised keys are preserved, never replaced, and the
   original sshd_config is kept at sshd_config.fleet-backup.

 OPTIONS
   -TargetUser <name>       Account to authorise. Defaults to the current user.
                            Under SYSTEM (scheduled task, RMM, guest agent) that
                            is the MACHINE account, so it falls back to the
                            console user, then to the sole enabled local account.
   -PublicKey <string>      Override the embedded fleet key.
   -Persist                 Leave sshd Automatic rather than session-only.
   -LocalAdmin <name>       Create (or reuse) this local administrator and
                            authorise the key for it instead of -TargetUser.
                            Automatic, as 'fleet', for Entra ID accounts.
   -NoLocalAdmin            For an Entra ID target, stop with an explanation
                            instead of creating a local administrator.
   -NoMsiDownload           Do not fetch the official OpenSSH MSI; print manual
                            install instructions instead.
   -DownloadTimeoutSec <n>  Hard ceiling on the MSI download. Default 180.
   -MsiTimeoutSec <n>       Hard ceiling on the MSI install. Default 300.
   -AllowPasswordAuth       Keep SSH password authentication enabled. OFF by
                            default: this script turns SSH ON, and leaving
                            passwords accepted would expose every local (and
                            domain) account to online guessing. Only use it if
                            something else already relies on SSH passwords.
   -AllowBlankPasswordAuth  Only if the self-test is actively REFUSED on a
                            blank-password account. Relaxes LimitBlankPasswordUse
                            machine-wide -- see the warning where it is used.
   -AnyRemote               Do not scope the firewall rule to LAN + tailnet.

 Exit codes: 0 success (or installed but unverified), 1 error or failed self-test,
 2 OpenSSH could not be installed (needs a human). Run in memory (the one-liner),
 a failure stops the script but leaves your PowerShell window open.

 Wiki: docs/wiki/infrastructure/windows-fleet-ssh-access.md
================================================================================
#>

[CmdletBinding()]
param(
    [string] $TargetUser = $env:USERNAME,
    [string] $PublicKey  = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDGR7mbMKs8alVN4K1ynvqT5K3KcXdeqlV77QQS0K1qy master-fleet-identity',
    [switch] $AllowBlankPasswordAuth,
    [switch] $AllowPasswordAuth,
    [switch] $AnyRemote,
    [switch] $Persist,
    [string] $LocalAdmin = 'fleet',
    [switch] $NoLocalAdmin,
    [switch] $NoMsiDownload,
    [int]    $DownloadTimeoutSec = 180,
    [int]    $MsiTimeoutSec = 300
)

$ErrorActionPreference = 'Stop'

# Bump on every behaviour change: it is printed in the diagnostic panel, so a
# photo of a failure says which version produced it.
$FleetSshVersion = '2026-11-22 (netsh firewall)'

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

$script:StopMarker = 'Setup-FleetSSH stopped'
function Stop-FleetSsh {
    <#
      End the run with an exit code WITHOUT killing the operator's window.
      Run as a file, `exit` ends the script. Run in memory -- the one-liner,
      iex (irm ...) -- `exit` ends the operator's whole PowerShell session and
      the window vanishes before the failure can be read or photographed. So in
      memory we stop by throwing a short, recognisable error instead; the trap
      below lets it through and the prompt comes back.
    #>
    param([int] $Code)
    $global:LASTEXITCODE = $Code
    if ($PSCommandPath) { exit $Code }
    throw "$($script:StopMarker) with code $Code -- the panel above has the details."
}

# ------------------------------------------------------- decision helpers ---
# Pure functions: no side effects and no Windows-only calls, so the unit tests
# (tools/windows/tests/) can extract and run them anywhere, pwsh on Linux included.

function Test-EntraAccount {
    # Cloud-only Entra ID (Azure AD) accounts carry SIDs under S-1-12-1 and show
    # up as AzureAD\<name>. dsregcmd's AzureAdJoined only describes the MACHINE: a
    # local account on an Entra-joined box is perfectly fine for key-only SSH.
    param([string] $Sid, [string] $Name)
    return ($Sid -like 'S-1-12-1-*') -or ($Name -match '^AzureAD\\')
}

function Select-ThirdPartyFirewall {
    # SecurityCenter2 FirewallProduct display names -> the ones that are NOT
    # Windows' own firewall. Any of those overrides our Windows Firewall rule.
    param([string[]] $DisplayNames)
    return @($DisplayNames | Where-Object {
        $_ -and $_ -notmatch '^(Windows|Microsoft) (Defender )?Firewall$|^Windows Defender$|^Microsoft Defender'
    } | Select-Object -Unique)
}

function Get-SelfTestVerdict {
    <#
      Classify the loopback ssh result:
        pass          exit 0 and whoami printed something
        refused       sshd rejected the key (bad file, ACL, wrong account name)
        closed        the key was ACCEPTED, then the session died as it opened:
                      sshd could not create a logon (Entra ID / unreachable DC)
        inconclusive  anything else -- never call the key bad on a guess
    #>
    param([int] $ExitCode, [string] $StdOut, [string] $StdErr)
    if ($ExitCode -eq 0 -and "$StdOut".Trim()) { return 'pass' }
    if ("$StdErr" -match 'Permission denied|Authentication failed|Invalid user|Too many authentication failures') { return 'refused' }
    if ("$StdErr" -match 'Connection closed|closed by remote host|Connection reset') { return 'closed' }
    return 'inconclusive'
}

function Format-DiagnosticPanel {
    <#
      The end-of-run panel, built to be photographed off a screen: fixed width,
      one fact per line, long values cut rather than wrapped. Takes an ordered
      dictionary of label -> value (a value may be an array: one line each).
    #>
    param([System.Collections.IDictionary] $Fields, [string] $Title, [int] $Width = 72)
    $inner = $Width - 4
    $out = @('+' + ('-' * ($Width - 2)) + '+')
    $t = " $Title"
    $out += '| ' + $t.Substring(0, [Math]::Min($t.Length, $inner)).PadRight($inner) + ' |'
    $out += '+' + ('-' * ($Width - 2)) + '+'
    foreach ($k in $Fields.Keys) {
        $vals = @($Fields[$k])
        if (-not $vals.Count) { $vals = @('') }
        $first = $true
        foreach ($v in $vals) {
            $label = if ($first) { "$k".PadRight(10) } else { ''.PadRight(10) }
            $line  = "$label $v"
            if ($line.Length -gt $inner) { $line = $line.Substring(0, $inner - 1) + '~' }
            $out += '| ' + $line.PadRight($inner) + ' |'
            $first = $false
        }
    }
    $out += '+' + ('-' * ($Width - 2)) + '+'
    return $out
}

function Get-ElevationArgs {
    # Rebuild the command line for the elevated re-launch from the parameters
    # the caller actually passed, so no switch is silently dropped on the way.
    param([string] $ScriptPath, [hashtable] $Bound)
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$ScriptPath`"")
    foreach ($k in ($Bound.Keys | Sort-Object)) {
        $v = $Bound[$k]
        if ($v -is [System.Management.Automation.SwitchParameter] -or $v -is [bool]) {
            if ([bool]$v) { $a += "-$k" }
        } else {
            $a += "-$k"; $a += "`"$v`""
        }
    }
    return $a
}

# --------------------------------------------------------- diagnostic panel ---
# Printed before EVERY exit once the account is known, so one photo of the
# screen carries everything needed to diagnose a failure from doc1. Also saved
# to C:\ProgramData\ssh\fleetssh-last-run.txt for reading over SSH later.
$script:SshdLogLines = @()
$script:KeyFiles     = @()
function Get-JoinState {
    # dsregcmd is a native exe: run it bounded so it can never hang the run.
    try {
        $f = Join-Path $env:TEMP ("fleet-dsreg-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
        $p = Start-Process dsregcmd.exe -ArgumentList '/status' -NoNewWindow -PassThru -RedirectStandardOutput $f
        $null = $p.Handle
        if (-not $p.WaitForExit(10000)) { try { $p.Kill() } catch {}; return 'unknown (dsregcmd timed out)' }
        $t = Get-Content $f -Raw; Remove-Item $f -Force -ErrorAction SilentlyContinue
        $v = { param($n) if ($t -match "(?m)^\s*$n\s*:\s*(\S.*?)\s*$") { $Matches[1] } else { '?' } }
        $tenant = & $v 'TenantName'
        return ("Entra={0} AD={1}{2}" -f (& $v 'AzureAdJoined'), (& $v 'DomainJoined'),
                $(if ($tenant -ne '?') { " tenant=$tenant" } else { '' }))
    } catch { return "unknown ($($_.Exception.Message))" }
}
function Get-SshdInfo {
    try {
        $img = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\sshd' -ErrorAction Stop).ImagePath
        $exe = $img.Trim('"').Split('"')[0]
        $src = if ($exe -match '\\System32\\OpenSSH\\') { 'Windows feature' } else { 'MSI' }
        $ver = (Get-Item $exe -ErrorAction Stop).VersionInfo.ProductVersion
        $svc = Get-Service sshd -ErrorAction Stop
        return "$ver $src, $($svc.Status)/$($svc.StartType)"
    } catch { return 'not installed' }
}
function Show-FleetPanel {
    param([string] $Result, [string[]] $ErrorText)
    $os = try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $b = [Environment]::OSVersion.Version.Build
        # ProductName still says "Windows 10" on Windows 11 (a Microsoft quirk).
        $n = if ($b -ge 22000) { $cv.ProductName -replace 'Windows 10', 'Windows 11' } else { $cv.ProductName }
        "$n $($cv.DisplayVersion) build $b"
    } catch { "build $([Environment]::OSVersion.Version.Build)" }
    $acct = if ($userSid) {
        $kind = if (Test-EntraAccount -Sid $userSid.Value -Name $requestedUser) { 'Entra' }
                elseif ($userSid.Value -like 'S-1-5-21-*' -and $requestedUser -like "$env:COMPUTERNAME\*") { 'local' }
                else { 'domain/other' }
        "$requestedUser [$kind]"
    } else { "$TargetUser [unresolved]" }
    $f = [ordered]@{
        'RESULT'   = $Result
        'script'   = $FleetSshVersion
        'host'     = "$env:COMPUTERNAME  $(@($ips) -join ', ')"
        'windows'  = $os
        'joined'   = (Get-JoinState)
        'account'  = $acct
        'sid'      = $(if ($userSid) { $userSid.Value } else { '-' })
        'admin'    = $(if ($null -ne $isAdminAccount) { "$(if ($isAdminAccount) { 'yes' } else { 'no' }) - $adminVia" } else { '-' })
        'ssh as'   = $(if ($retargeted) { "$TargetUser (local admin, retargeted)" } else { $TargetUser })
        'sshd'     = (Get-SshdInfo)
        'keyfiles' = $(if ($script:KeyFiles.Count) { $script:KeyFiles } else { '-' })
        'firewall' = $(if (@($thirdPartyFw).Count) { "THIRD-PARTY: $(@($thirdPartyFw) -join ', ')" } else { 'Windows only' })
        'selftest' = $(if ($verdict) { $verdict } else { 'not run' })
        'sshd log' = $(if ($script:SshdLogLines.Count) { $script:SshdLogLines } else { '-' })
    }
    if ($ErrorText) { $f['ERROR'] = $ErrorText }
    $lines = Format-DiagnosticPanel -Fields $f -Title "FLEET SSH -- photograph this panel"
    $color = if ($Result -like 'PASS*') { 'Green' } elseif ($Result -like 'WARN*') { 'Yellow' } else { 'Red' }
    Write-Host ""
    $lines | ForEach-Object { Write-Host $_ -ForegroundColor $color }
    try {
        if (Test-Path $SshDataDir) {
            [IO.File]::WriteAllText((Join-Path $SshDataDir 'fleetssh-last-run.txt'),
                (($lines + @('', "written $(Get-Date -Format s)")) -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
        }
    } catch {}
}
function Get-LanIps {
    try {
        return @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | Select-Object -ExpandProperty IPAddress)
    } catch { return @() }
}
# Any unexpected terminating error still ends with the panel, carrying the
# error and the line it came from, instead of a bare red PowerShell error that
# says nothing about the box. (On the first #240 test run an over-long account
# description killed the run with no output at all.)
trap {
    $err = $_
    # Our own deliberate stop (in-memory mode): let it end the script quietly.
    if ("$($err.Exception.Message)".StartsWith($script:StopMarker)) { break }
    Write-Host ""
    Write-Fail "Unexpected error: $($err.Exception.Message)"
    $where = "line $($err.InvocationInfo.ScriptLineNumber): $("$($err.InvocationInfo.Line)".Trim())"
    $ips = Get-LanIps
    Show-FleetPanel -Result 'FAIL-SCRIPT-ERROR (send this photo)' -ErrorText @(
        ($err.Exception.Message -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 3) + $where)
    $global:LASTEXITCODE = 1
    if ($PSCommandPath) { exit 1 }
    break   # in memory: stop the script, keep the operator's window
}

$ips = @()
$isAdminAccount = $null
$adminVia = '-'
$thirdPartyFw = @()
$verdict = $null
$retargeted = $false
$requestedUser = $TargetUser

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
        Stop-FleetSsh 1
    }
    Write-Host "Not elevated. Re-launching as Administrator..." -ForegroundColor Yellow
    $argList = Get-ElevationArgs -ScriptPath $PSCommandPath -Bound $PSBoundParameters
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
            # Strip the prefix only from a LOCAL account (HOST\name). Keep it for
            # AzureAD\name and DOMAIN\name: those resolve, and are detected as
            # Entra, only in full.
            $TargetUser = if ($console -like "$env:COMPUTERNAME\*") { ($console -split '\\')[-1] } else { $console }
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
$userSid = $null
$me = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($TargetUser -eq $env:USERNAME -and $me.User -and $me.Name -notmatch '\$$') {
    # Ourselves: take the SID from our own token. Re-translating the bare
    # $env:USERNAME is exactly what goes wrong for an Entra account, whose
    # short name is not a resolvable account name.
    $userSid = $me.User
} else {
    try {
        $userSid = (New-Object Security.Principal.NTAccount($TargetUser)).Translate(
                       [Security.Principal.SecurityIdentifier])
    } catch {
        Write-Fail "No such account: $TargetUser"
        Write-Info "Enabled local accounts on this box:"
        try { Get-LocalUser | Where-Object Enabled | ForEach-Object { Write-Info "  $($_.Name)" } } catch {}
        Write-Info "Re-run with:  -TargetUser <name>   (Entra ID accounts: AzureAD\<name>)"
        $ips = Get-LanIps; Show-FleetPanel -Result 'FAIL-NO-SUCH-ACCOUNT'
        Stop-FleetSsh 1
    }
}
$accountName = try { $userSid.Translate([Security.Principal.NTAccount]).Value } catch { $TargetUser }
Write-Ok "SID $($userSid.Value)  ($accountName)"

# ----------------------------------------- Entra ID -> local administrator ---
# See ENTRA ID in the header. Key-only SSH as a cloud-only Entra account is
# accepted and then closed by sshd, so we authorise a local admin instead.
$requestedUser = $accountName
$isEntra       = Test-EntraAccount -Sid $userSid.Value -Name $accountName
if ($isEntra) { Write-Warn "'$accountName' is an Entra ID (Azure AD) account: key-only SSH cannot log it on." }

if ($isEntra -or $PSBoundParameters.ContainsKey('LocalAdmin')) {
    if ($isEntra -and $NoLocalAdmin) {
        Write-Fail "Refusing to continue: -NoLocalAdmin was given and '$accountName' is an Entra ID account."
        Write-Info "sshd would accept the key and then close the session as it opens (no password -> no logon token)."
        Write-Info "Re-run without -NoLocalAdmin to create a local administrator for SSH, or target a local account."
        $ips = Get-LanIps; Show-FleetPanel -Result 'FAIL-ENTRA-NOLOCALADMIN'
        Stop-FleetSsh 1
    }
    Write-Step "Local administrator '$LocalAdmin' for SSH"
    $lu = Get-LocalUser -Name $LocalAdmin -ErrorAction SilentlyContinue
    if ($lu) {
        if (-not $lu.Enabled) { Enable-LocalUser -Name $LocalAdmin; Write-Ok "Re-enabled existing account '$LocalAdmin'." }
        else { Write-Ok "Using existing local account '$LocalAdmin'." }
    } else {
        # Random and immediately discarded: it is never shown or stored. Key auth
        # never asks for it, and nobody should ever log on to this account
        # interactively. The suffix guarantees every complexity class.
        $pw = ConvertTo-SecureString ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N') + 'Aa1!') `
                  -AsPlainText -Force
        $lu = New-LocalUser -Name $LocalAdmin -Password $pw -PasswordNeverExpires -AccountNeverExpires `
                  -Description 'doc1 fleet SSH, key only (Setup-FleetSSH.ps1)'   # max 48 chars
        Remove-Variable pw
        Write-Ok "Created local account '$LocalAdmin' (random password, not recorded)."
    }
    # Do NOT enumerate Administrators first: on Entra-joined boxes
    # Get-LocalGroupMember throws ("Failed to compare two elements") because of
    # the Entra SIDs in the group. Just add, and treat "already a member" as fine.
    try {
        Add-LocalGroupMember -SID $SID_ADMINS -Member $lu.SID.Value -ErrorAction Stop
        Write-Ok "Added '$LocalAdmin' to Administrators."
    } catch {
        if ($_.Exception.Message -match 'already a member|MemberExists') {
            Write-Ok "'$LocalAdmin' is already in Administrators."
        } else {
            # Fallback without the LocalAccounts module, by the localised group name.
            $grp = (New-Object Security.Principal.SecurityIdentifier($SID_ADMINS)).Translate(
                       [Security.Principal.NTAccount]).Value.Split('\')[-1]
            $o = & net.exe localgroup "$grp" $LocalAdmin /add 2>&1
            if ($LASTEXITCODE -ne 0 -and "$o" -notmatch '1378|already a member') {
                Write-Fail "Could not add '$LocalAdmin' to Administrators: $($_.Exception.Message) / $o"
                $ips = Get-LanIps; Show-FleetPanel -Result 'FAIL-LOCALADMIN-GROUP'
                Stop-FleetSsh 1
            }
            Write-Ok "Added '$LocalAdmin' to Administrators (net localgroup)."
        }
    }
    $TargetUser  = $LocalAdmin
    $userSid     = $lu.SID
    $accountName = "$env:COMPUTERNAME\$LocalAdmin"
    $retargeted  = $true
    Write-Ok "Retargeted: the key goes to '$LocalAdmin', not '$requestedUser'."
}

# Is the account a local Administrator? That decides which authorized-keys file
# sshd will actually read, and sshd decides by TOKEN membership, groups
# included. Direct membership is not enough: on an Entra-joined box an Entra
# user is usually an admin only through a role group (an S-1-12-1 SID) inside
# Administrators. Missing that wrote the key to the wrong file on a real office PC.
#  * The account running this script: it is elevated (checked above), so it
#    IS an administrator -- whichever group got it there.
#  * Anyone else: direct membership by SID (locale-proof); nested and
#    role-group membership cannot be resolved offline, so say so.
$isAdminAccount = $false
$adminVia = 'not a member of Administrators'
if ($retargeted) {
    $isAdminAccount = $true
    $adminVia = 'local admin created/confirmed by this script'
} elseif ($me.User -and $userSid.Value -eq $me.User.Value) {
    $isAdminAccount = $true
    $adminVia = 'this elevated session'
} else {
    try {
        $isAdminAccount = [bool](@(Get-LocalGroupMember -SID $SID_ADMINS -ErrorAction Stop |
            Where-Object { $_.SID.Value -eq $userSid.Value }).Count)
        if ($isAdminAccount) { $adminVia = 'direct member of Administrators' }
    } catch {
        # Get-LocalGroupMember chokes on orphaned/Entra SIDs left in the group.
        $adminVia = 'unknown (Administrators could not be enumerated)'
        Write-Warn "Could not enumerate Administrators; assuming '$TargetUser' is NOT an admin."
    }
}
Write-Ok ("Administrator: {0}  ({1})" -f $(if ($isAdminAccount) { 'yes' } else { 'no' }), $adminVia)

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
    # Reached when the MSI could not be fetched or installed (no route to
    # GitHub, a signature that does not verify, a held MSI mutex), or with
    # -NoMsiDownload. Tell the operator exactly what to do and get out of the way.
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
    Write-Info "Nothing has been changed on this machine. Re-running is always safe."
    Write-Host ""
}

function Install-OpenSSHFromMsi {
    <#
      Fetch and install the official Win32-OpenSSH MSI -- the only install route.

      We are already running a script fetched from GitHub as Administrator, so
      pulling Microsoft's own signed OpenSSH package from the same origin adds no
      meaningful trust surface -- and it turns "go and do this by hand" into
      "it just worked". The Authenticode signature IS verified before anything is
      executed, so a tampered or truncated download is refused rather than run.
      -NoMsiDownload opts out entirely.
    #>
    [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
    $msi = Join-Path $env:TEMP 'OpenSSH-Win64-fleet.msi'
    $url = $null

    # Prefer whatever is current; fall back to a known-good pin, because
    # api.github.com is blocked on some sites where raw.githubusercontent is not.
    try {
        $rel = Invoke-RestMethod 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest' -TimeoutSec 20
        $url = ($rel.assets | Where-Object { $_.name -like 'OpenSSH-Win64*.msi' } | Select-Object -First 1).browser_download_url
    } catch {}
    if (-not $url) {
        $url = 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-Win64-v10.0.0.0.msi'
        Write-Info "Release API unreachable; using the pinned build."
    }

    Write-Info "Downloading $($url.Split('/')[-1]) (up to ${DownloadTimeoutSec}s) ..."
    # NOT Invoke-WebRequest. Its -TimeoutSec bounds the initial response only,
    # not the transfer, so a stalled connection hangs indefinitely -- and in
    # PowerShell 5.1 its progress rendering makes a multi-megabyte download
    # crawl. WebClient with a bounded Task gives a hard ceiling and no progress
    # overhead.
    $prevPP = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    $wc = New-Object Net.WebClient
    try {
        $task = $wc.DownloadFileTaskAsync([Uri]$url, $msi)
        if (-not $task.Wait([TimeSpan]::FromSeconds($DownloadTimeoutSec))) {
            try { $wc.CancelAsync() } catch {}
            Write-Warn "Download timed out after ${DownloadTimeoutSec}s."
            return $false
        }
        if ($task.IsFaulted) { throw $task.Exception.GetBaseException() }
    } catch {
        Write-Warn "Download failed: $($_.Exception.Message)"
        return $false
    } finally {
        $ProgressPreference = $prevPP
        try { $wc.Dispose() } catch {}
    }
    $size = (Get-Item $msi -ErrorAction SilentlyContinue).Length
    if (-not $size -or $size -lt 1MB) { Write-Warn "Download looks truncated ($size bytes)."; return $false }
    Write-Ok "Downloaded $([math]::Round($size/1MB,1)) MB."

    $sig = Get-AuthenticodeSignature $msi
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft') {
        Write-Fail "Refusing to install: MSI signature is '$($sig.Status)' from '$($sig.SignerCertificate.Subject)'."
        Remove-Item $msi -Force -ErrorAction SilentlyContinue
        return $false
    }
    Write-Ok "MSI signature valid (Microsoft)."

    # Bounded, not -Wait: msiexec blocks indefinitely if another installation
    # already holds the _MSIExecute mutex.
    Write-Info "Installing (up to ${MsiTimeoutSec}s) ..."
    $p = Start-Process msiexec.exe -PassThru -NoNewWindow `
            -ArgumentList '/i',"`"$msi`"",'ADDLOCAL=Server','/quiet','/norestart'
    $null = $p.Handle
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt $MsiTimeoutSec) { Start-Sleep -Seconds 3 }
    if (-not $p.HasExited) {
        try { $p.Kill() } catch {}
        Write-Warn "msiexec did not finish within ${MsiTimeoutSec}s (another install may hold the MSI mutex)."
        Remove-Item $msi -Force -ErrorAction SilentlyContinue
        return $false
    }
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0) { Write-Warn "msiexec exited $($p.ExitCode)."; return $false }
    return $true
}

$sshdSvc = Get-Service -Name sshd -ErrorAction SilentlyContinue
if ($sshdSvc) {
    Write-Ok "sshd already installed."
} else {
    Write-Info "sshd not present."
    $installError = 'run with -NoMsiDownload'
    if (-not $NoMsiDownload) {
        $installError = 'the OpenSSH MSI could not be downloaded or installed (see above)'
        if (Install-OpenSSHFromMsi) {
            $sshdSvc = Get-Service -Name sshd -ErrorAction SilentlyContinue
            if ($sshdSvc) { Write-Ok "OpenSSH Server installed (MSI)." }
            else { $installError = 'the MSI installed but no sshd service appeared' }
        }
    }
    if (-not $sshdSvc) {
        Show-ManualInstallHelp -Reason $installError
        $ips = Get-LanIps; Show-FleetPanel -Result 'FAIL-NO-SSHD (see manual steps above)'
        Stop-FleetSsh 2
    }
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
if (-not (Test-Path $SshDataDir)) {
    Write-Fail "$SshDataDir missing -- sshd has never started."
    $ips = Get-LanIps; Show-FleetPanel -Result 'FAIL-SSHD-NEVER-STARTED'
    Stop-FleetSsh 1
}

# ----------------------------------------------------------------- firewall ---
Write-Step "Firewall (TCP 22 inbound)"
# Guarantee our OWN port-keyed rule exists and is enabled (which also undoes a
# previous "close"). A pre-existing rule whose name matches /SSH/ is NOT proof
# the port is open: Windows firewall rules are often PROGRAM-scoped, and a rule
# pointing at an sshd.exe that no longer exists (e.g. OpenSSH moved from Features
# on Demand to the MSI, at a different path) enumerates perfectly and permits
# nothing. Observed live: sshd Running, an enabled "OpenSSH SSH Server Preview
# (sshd)" rule present, and port 22 still refusing. A PORT rule cannot go stale.
#
# netsh in a killable process, never the NetSecurity cmdlets: Get-NetFirewallRule
# goes through CIM with no timeout and stalled MEAGANS_LAPTOP for 20+ minutes
# (2026-11-22) right after the MSI install, with sshd running and port 22 already
# open, holding up the key. The rule must never block the key step: on a timeout we warn and go
# on, and `nc -vz <ip> 22` from doc1 settles whether the port is open.
# Same display name as the old New-NetFirewallRule rule, so netsh finds those.
$FleetRuleName = 'Fleet SSH (TCP 22 inbound)'
function Invoke-Netsh {
    # -> netsh exit code, or $null if it did not finish within $TimeoutMs (killed).
    param([string] $Arguments, [int] $TimeoutMs = 20000)
    $out = Join-Path $env:TEMP ("fleet-netsh-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    try {
        $p = Start-Process netsh.exe -ArgumentList $Arguments -NoNewWindow -PassThru `
                 -RedirectStandardOutput $out
        $null = $p.Handle   # cache the native handle, or .ExitCode reads back empty
        if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch {}; return $null }
        return $p.ExitCode
    } catch { return $null
    } finally { Remove-Item $out -Force -ErrorAction SilentlyContinue }
}
$rc = Invoke-Netsh "advfirewall firewall show rule name=`"$FleetRuleName`""
if ($null -eq $rc) {
    Write-Warn "Windows Firewall did not answer within 20s; rule step skipped. Check from doc1: nc -vz <ip> 22"
} elseif ($rc -eq 0) {
    $rc = Invoke-Netsh "advfirewall firewall set rule name=`"$FleetRuleName`" new enable=yes"
    if ($rc -eq 0) { Write-Ok "Port rule '$FleetRuleName' present and enabled." }
    else { Write-Warn "Could not enable '$FleetRuleName' (netsh rc=$rc). Check from doc1: nc -vz <ip> 22" }
} else {
    # Tailscale subnet routers SNAT by default, so traffic from doc1 arrives
    # sourced from the subnet router's own LAN address -- hence the local /16.
    $scope = if ($AnyRemote) { '' } else { ' remoteip=192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,100.64.0.0/10' }
    $rc = Invoke-Netsh ("advfirewall firewall add rule name=`"$FleetRuleName`" dir=in action=allow " +
                        "protocol=TCP localport=22 profile=any enable=yes$scope")
    if ($rc -eq 0) { Write-Ok "Created port rule '$FleetRuleName'$(if (-not $AnyRemote) { ' scoped to LAN + tailnet' })" }
    else { Write-Warn "Could not create '$FleetRuleName' (netsh rc=$(if ($null -eq $rc) { 'timeout' } else { $rc })). Check from doc1: nc -vz <ip> 22" }
}

# A third-party firewall (OEM McAfee/Norton trialware) registered with Security
# Center drops inbound traffic whatever the Windows Firewall rules say, and the
# loopback self-test cannot see it. SecurityCenter2 exists on client SKUs only;
# bounded so a sick WMI service cannot hang the run.
try {
    $fwNames = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName 'FirewallProduct' `
                     -OperationTimeoutSec 15 -ErrorAction Stop | ForEach-Object { $_.displayName })
    $thirdPartyFw = @(Select-ThirdPartyFirewall -DisplayNames $fwNames)
} catch {}
foreach ($fw in $thirdPartyFw) {
    Write-Warn "$fw is active and will override the Windows Firewall rule. Uninstall it (Settings > Apps) or allow inbound TCP 22 in it."
}
if (-not $thirdPartyFw.Count) { Write-Ok "No third-party firewall registered." }

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
    Write-Fail "That does not look like an OpenSSH public key."; Stop-FleetSsh 1
}

$userKeys = if ($hasProfile) { Join-Path $profilePath '.ssh\authorized_keys' } else { $null }

# Both files are written on purpose. Which one sshd consults depends on the
# `Match Group administrators` block in sshd_config; writing both means the key
# works whether or not that block is present and whether or not the account is
# an admin. Both end up locked down, so the extra file costs nothing.
if ($isAdminAccount) {
    $had = Add-AuthorizedKey -Path $AdminKeys -Key $PublicKey -AllowSids @($SID_SYSTEM, $SID_ADMINS)
    $script:KeyFiles += $AdminKeys
    Write-Ok ("{0}  ({1})" -f $AdminKeys, $(if ($had) { 'already present' } else { 'KEY ADDED' }))
}
if ($userKeys) {
    $had = Add-AuthorizedKey -Path $userKeys -Key $PublicKey -AllowSids @($SID_SYSTEM, $SID_ADMINS, $userSid.Value)
    $script:KeyFiles += $userKeys
    Write-Ok ("{0}  ({1})" -f $userKeys, $(if ($had) { 'already present' } else { 'KEY ADDED' }))
} elseif (-not $isAdminAccount) {
    Write-Fail "'$TargetUser' is not an administrator and has no profile, so there is nowhere sshd will look for its key."
    Write-Info "Log in as '$TargetUser' once to create the profile, then re-run."
    $ips = Get-LanIps; Show-FleetPanel -Result 'FAIL-NO-KEYFILE (non-admin, no profile)'
    Stop-FleetSsh 1
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

# Key-only by DEFAULT. Enabling sshd while leaving password auth on exposes every
# local (and, on a domain member, domain) account to online password guessing --
# a strictly worse position than the box was in before we touched it. We are here
# to install a key, so passwords buy us nothing. -AllowPasswordAuth keeps them,
# for a box where something else already relies on SSH password logins.
# Set BEFORE the self-test, so the self-test proves key auth against the final
# configuration rather than one we are about to change underneath it.
$sshdOpts = [ordered]@{ 'PubkeyAuthentication' = 'yes' }
if (-not $AllowPasswordAuth) {
    $sshdOpts['PasswordAuthentication'] = 'no'
    $sshdOpts['PermitEmptyPasswords']   = 'no'
}
Set-SshdManagedBlock -Options $sshdOpts
Restart-Service sshd
if ($AllowPasswordAuth) {
    Write-Warn "PasswordAuthentication left ENABLED at your request."
} else {
    Write-Ok "Key-only: PubkeyAuthentication yes, PasswordAuthentication no."
}
Write-Info "Original sshd_config saved as sshd_config.fleet-backup." 

# ---------------------------------------------------------------- self-test ---
# Proves the whole chain with a real SSH login over loopback using a throwaway
# key. This is what catches the blank-password S4U problem, a bad ACL, or a
# mis-scoped sshd_config -- now, rather than after you have walked away.
Write-Step "Self-test: real key login over loopback"
$testStart = Get-Date
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
        $verdict = Get-SelfTestVerdict -ExitCode $proc.ExitCode -StdOut "$so" -StdErr "$se"
        $errLines = @("$se".Trim() -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 8)
        switch ($verdict) {
            'pass' {
                $testPass = $true
                Write-Ok "Key authentication WORKS. Remote whoami: $("$so".Trim())"
            }
            'refused' {
                # sshd actively rejected the key -- a real, actionable failure.
                Write-Fail "Key authentication was REFUSED (exit $($proc.ExitCode))."
                $errLines | ForEach-Object { Write-Info "  $_" }
            }
            'closed' {
                # The key was accepted and the session died as it opened: sshd
                # could not create a logon for this account.
                Write-Fail "The key was accepted, then sshd closed the session as it opened."
                Write-Info "sshd could not create a logon for '$TargetUser'. That is what an Entra ID account"
                Write-Info "or a domain account whose domain controller is unreachable looks like."
                Write-Info "Fix: re-run with  -LocalAdmin fleet  and SSH as that account instead."
            }
            default {
                # Non-zero, but nothing that looks like a refusal (client quirk,
                # loopback oddity, ...). Do NOT claim the key is bad -- say so
                # honestly and let the doc1 check be the decider.
                $testInconclusive = $true
                Write-Warn "Self-test inconclusive (exit $($proc.ExitCode)) -- no sign of an actual refusal."
                $errLines | Select-Object -First 6 | ForEach-Object { Write-Info "  $_" }
                Write-Info "The key IS installed; verify from doc1 (command shown below)."
            }
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

# The sshd log says in one line what went wrong ("Invalid user X", "Failed
# publickey", "Connection closed"), so on any failure show it rather than
# telling the operator to go and fetch it.
if (-not $testPass) {
    Write-Step "sshd log since the self-test (OpenSSH/Operational)"
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'OpenSSH/Operational'; StartTime = $testStart.AddSeconds(-2) } `
                    -MaxEvents 12 -ErrorAction Stop | Sort-Object TimeCreated)
        foreach ($e in $ev) {
            $msg = ($e.Message -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
            # sshd prefixes every line with "sshd: PID <n>: " -- noise on a photo.
            $msg = $msg -replace '^sshd(-session)?: PID \d+: ', ''
            Write-Info ("  {0:HH:mm:ss}  {1}" -f $e.TimeCreated, $msg)
            if ($msg -notmatch '^(Server listening|Received disconnect|Disconnected from)') { $script:SshdLogLines += $msg }
        }
        $script:SshdLogLines = @($script:SshdLogLines | Select-Object -Last 5)
    } catch {
        Write-Info "  (no events: $($_.Exception.Message))"
    }
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

# ----------------------------------------------------------------- summary ----
Write-Step "Summary"
$ips = Get-LanIps

Write-Host ""
Write-Host "  hostname : $env:COMPUTERNAME"
Write-Host "  user     : $TargetUser$(if ($retargeted) { "   (instead of $requestedUser)" })"
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
if ($retargeted) {
    $why = if ($isEntra) { 'Entra ID account detected' } else { 'Local administrator requested' }
    Write-Host "  $why -- SSH as $TargetUser@$addr, not $requestedUser." -ForegroundColor Cyan
    Write-Host ""
}
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
    Write-Host "  NOT VERIFIED -- the self-test login failed. The sshd log above says why." -ForegroundColor Red
}
Write-Host ""
Write-Host "  The self-test runs over loopback, so it cannot see a firewall or the network."
Write-Host "  Final check from doc1:  nc -vz -w5 $addr 22"
Write-Host "    timeout -> something is dropping packets (third-party firewall, network);"
Write-Host "    refused -> nothing listening on 22.  Then:  ssh $TargetUser@$addr whoami"

if ($script:Warnings.Count) {
    Write-Host ""
    Write-Host "  Warnings raised:" -ForegroundColor Yellow
    $script:Warnings | ForEach-Object {
        Write-Host "    - $(($_ -split "`n" | Select-Object -First 1).Trim())" -ForegroundColor Yellow
    }
}

$result = switch ($verdict) {
    'pass'    { if (@($thirdPartyFw).Count) { 'WARN-PASS-LOCAL (third-party firewall: check from doc1)' } else { 'PASS' } }
    'refused' { 'FAIL-REFUSED (key rejected; see sshd log)' }
    'closed'  { 'FAIL-SESSION-CLOSED (no logon token; use -LocalAdmin)' }
    default   { 'WARN-UNVERIFIED (self-test inconclusive; check from doc1)' }
}
Show-FleetPanel -Result $result
Write-Host ""
if ($verdict -in @('refused', 'closed')) { Stop-FleetSsh 1 }
# Success: say so explicitly. Otherwise the run "returns" whatever the last
# native tool left in $LASTEXITCODE (-1 on the first VM test), and an RMM or
# guest-agent caller reads a working run as a failure.
$global:LASTEXITCODE = 0
