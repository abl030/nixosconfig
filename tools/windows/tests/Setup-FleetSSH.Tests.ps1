<#
  Offline unit tests for tools/windows/Setup-FleetSSH.ps1 (and a parse check of
  every tools/windows/*.ps1). No Pester, no Windows: runs under pwsh anywhere.

    pwsh -NoProfile -File tools/windows/tests/Setup-FleetSSH.Tests.ps1

  The script runs top-level code when loaded, so it is never dot-sourced here.
  Instead the PowerShell parser pulls out the named pure helper functions and
  only those are defined. Exit 0 when every assertion holds, 1 otherwise.

  The integration side (real installs, real logins, run from doc1 against a
  throwaway Windows VM) is tools/windows/tests/fleetssh-vm-matrix.sh.
#>
$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'Setup-FleetSSH.ps1'
$script:Failures = 0
$script:Count    = 0

function Assert-Equal {
    param($Expected, $Actual, [string] $Name)
    $script:Count++
    # Compare as arrays: PowerShell unwraps an empty array returned from a
    # function to $null, and the script's callers always re-wrap with @().
    $e = ConvertTo-Json -InputObject @($Expected) -Compress -Depth 4
    $a = ConvertTo-Json -InputObject @($Actual)   -Compress -Depth 4
    if ($e -ne $a) {
        $script:Failures++
        Write-Host "FAIL  $Name`n      expected $e`n      actual   $a" -ForegroundColor Red
    } else {
        Write-Host "ok    $Name"
    }
}

# ---- parse every Windows script: a syntax error must never reach a pinned URL
foreach ($f in Get-ChildItem (Join-Path $root '*.ps1')) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    Assert-Equal 0 @($errors).Count "parses: $($f.Name)"
    foreach ($e in $errors) { Write-Host "      $($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor Red }
}

# ---- load only the pure helpers out of the script ---------------------------
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$null)
$want = 'Test-EntraAccount', 'Select-ThirdPartyFirewall', 'Get-SelfTestVerdict', 'Get-SshLoginName', 'Test-ServiceDeletePending', 'Get-ElevationArgs', 'Format-DiagnosticPanel',
        'Get-InstallerOutcome', 'Get-OpenSshCapabilityName', 'Select-OpenSshProductCode', 'Select-MsiFailureContext'
foreach ($name in $want) {
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) |
          Select-Object -First 1
    if (-not $fn) { throw "helper $name not found in $script" }
    . ([scriptblock]::Create($fn.Extent.Text))
}

# ---- Test-EntraAccount (#240) -----------------------------------------------
Assert-Equal $true  (Test-EntraAccount -Sid 'S-1-12-1-1234567890-1234567890-1234567890-1234567890' -Name 'AzureAD\someone') 'entra: S-1-12-1 SID + AzureAD name'
Assert-Equal $true  (Test-EntraAccount -Sid 'S-1-12-1-1-2-3-4' -Name 'someone')        'entra: SID alone is enough'
Assert-Equal $true  (Test-EntraAccount -Sid '' -Name 'AzureAD\someone')                 'entra: AzureAD\ name alone is enough'
Assert-Equal $true  (Test-EntraAccount -Sid '' -Name 'azuread\someone')                 'entra: name match is case-insensitive'
Assert-Equal $false (Test-EntraAccount -Sid 'S-1-5-21-1-2-3-1001' -Name 'HOST\fleet')   'entra: local account is not Entra'
Assert-Equal $false (Test-EntraAccount -Sid 'S-1-5-21-9-8-7-1105' -Name 'CORP\bob')     'entra: AD domain account is not Entra'
Assert-Equal $false (Test-EntraAccount -Sid 'S-1-12-10-1' -Name 'x')                    'entra: S-1-12-10 is not S-1-12-1'

# ---- Select-ThirdPartyFirewall (#240 second failure mode) --------------------
Assert-Equal @('McAfee Firewall') (Select-ThirdPartyFirewall -DisplayNames @('Windows Firewall', 'McAfee Firewall')) 'firewall: McAfee reported, Windows ignored'
Assert-Equal 0 @(Select-ThirdPartyFirewall -DisplayNames @('Windows Defender Firewall', 'Microsoft Defender Firewall', 'Windows Firewall')).Count 'firewall: Windows own names ignored'
Assert-Equal @('Norton Smart Firewall', 'McAfee Firewall') (Select-ThirdPartyFirewall -DisplayNames @('Norton Smart Firewall', 'McAfee Firewall', 'McAfee Firewall')) 'firewall: several, de-duplicated'
Assert-Equal 0 @(Select-ThirdPartyFirewall -DisplayNames @()).Count 'firewall: none registered (as the script calls it)'
Assert-Equal 0 @(Select-ThirdPartyFirewall -DisplayNames @($null, '')).Count 'firewall: blank names ignored'

# ---- Get-SshLoginName / Test-ServiceDeletePending ------------------------------
Assert-Equal 'Administrator@CONTOSO' (Get-SshLoginName -AccountName 'CONTOSO\Administrator' -ComputerName 'PC-A' -Fallback 'Administrator') 'login: domain account is name@DOMAIN '
Assert-Equal 'alice@CONTOSO' (Get-SshLoginName -AccountName 'CONTOSO\alice' -ComputerName 'PC-A' -Fallback 'alice') 'login: domain user'
Assert-Equal 'bob' (Get-SshLoginName -AccountName 'PC-A\bob' -ComputerName 'pc-a' -Fallback 'bob') 'login: local account stays bare (case-insensitive host)'
Assert-Equal 'fleet' (Get-SshLoginName -AccountName 'PC-A\fleet' -ComputerName 'PC-A' -Fallback 'fleet') 'login: retargeted local admin stays bare'
Assert-Equal 'x' (Get-SshLoginName -AccountName 'AzureAD\x' -ComputerName 'PC' -Fallback 'x') 'login: Entra stays bare'
Assert-Equal 'solo' (Get-SshLoginName -AccountName 'solo' -ComputerName 'PC' -Fallback 'solo') 'login: unqualified falls back'
Assert-Equal $true  (Test-ServiceDeletePending "Service 'OpenSSH SSH Server (sshd)' cannot be configured due to the following error: The specified service has been marked for deletion") 'delete-pending: seen in the field'
Assert-Equal $false (Test-ServiceDeletePending 'Access is denied') 'delete-pending: other errors are not'

# ---- stale OpenSSH before the MSI (office PC, 2026-11-24) -------------------
Assert-Equal 'ok'     (Get-InstallerOutcome 0)    'installer: 0 ok'
Assert-Equal 'reboot' (Get-InstallerOutcome 3010) 'installer: 3010 reboot'
Assert-Equal 'reboot' (Get-InstallerOutcome 1641) 'installer: 1641 reboot'
Assert-Equal 'absent' (Get-InstallerOutcome 1605) 'installer: 1605 product already gone'
Assert-Equal 'fail'   (Get-InstallerOutcome 1603) 'installer: 1603 fail'
Assert-Equal @('OpenSSH.Server~~~~0.0.1.0', 'OpenSSH.Client~~~~0.0.1.0') (Get-OpenSshCapabilityName -PackageNames @(
    'OpenSSH-Server-Package~31bf3856ad364e35~amd64~~10.0.26100.1',
    'OpenSSH-Client-Package~31bf3856ad364e35~amd64~~10.0.26100.1',
    'OpenSSH-Client-Package~31bf3856ad364e35~wow64~~10.0.26100.1',
    'Microsoft-Windows-Foo-Package~31bf3856ad364e35~amd64~~10.0.1')) 'capability: CBS package names -> capability names, de-duplicated'
Assert-Equal 0 @(Get-OpenSshCapabilityName -PackageNames @()).Count 'capability: none installed'
$entries = @(
    [pscustomobject]@{ Name = '{c4a3e1b2-0000-4000-8000-1234567890ab}'; DisplayName = 'OpenSSH' },
    [pscustomobject]@{ Name = '{11111111-2222-3333-4444-555555555555}'; DisplayName = 'Some Other App' },
    [pscustomobject]@{ Name = 'OpenSSH-NotMsi'; DisplayName = 'OpenSSH (zip)' },
    $null)
Assert-Equal @('{C4A3E1B2-0000-4000-8000-1234567890AB}') (Select-OpenSshProductCode -Entries $entries) 'msi product: only GUID-keyed OpenSSH entries'
Assert-Equal 0 @(Select-OpenSshProductCode -Entries @()).Count 'msi product: none registered'
$log = @(
    'MSI (s) (A4:0C) [10:12:10:001]: Note: 1: 2203 2: C:\Windows\TEMP\OpenSSH-Win64-fleet.msi 3: -2147287038',
    'MSI (s) (A4:0C) [10:12:11:002]: Doing action: SetPrivilegesOnSshAgent',
    'Action start 10:12:11: SetPrivilegesOnSshAgent.',
    'MSI (s) (A4:10) [10:12:12:003]: Invoking remote custom action. DLL: C:\Windows\Installer\MSI1.tmp',
    'CustomAction SetPrivilegesOnSshAgent returned actual error code 1603 (note this may not be 100% accurate)',
    '',
    'Action ended 10:12:13: SetPrivilegesOnSshAgent. Return value 3.',
    'Action ended 10:12:14: INSTALL. Return value 3.')
Assert-Equal @(
    'CustomAction SetPrivilegesOnSshAgent returned actual error code 1603 (note this may not be 100% accurate)',
    'Doing action: SetPrivilegesOnSshAgent',
    'Action start 10:12:11: SetPrivilegesOnSshAgent.',
    'Invoking remote custom action. DLL: C:\Windows\Installer\MSI1.tmp',
    'Action ended 10:12:13: SetPrivilegesOnSshAgent. Return value 3.') (Select-MsiFailureContext -Lines $log) 'msi log: error line, then the first Return value 3 with its lead-up, prefixes stripped'
Assert-Equal @("no 'Return value 3' in the log") (Select-MsiFailureContext -Lines @('MSI (s) (A4:0C) [10:12:10:001]: Product: OpenSSH -- Installation completed successfully.')) 'msi log: nothing to show'
Assert-Equal @('Return value 3.') (Select-MsiFailureContext -Lines @('Return value 3.')) 'msi log: Return value 3 on the first line'

# ---- Get-SelfTestVerdict -----------------------------------------------------
Assert-Equal 'pass'    (Get-SelfTestVerdict -ExitCode 0 -StdOut "host\fleet`r`n" -StdErr '') 'verdict: pass'
Assert-Equal 'inconclusive' (Get-SelfTestVerdict -ExitCode 0 -StdOut '' -StdErr '') 'verdict: exit 0 but no whoami is not a pass'
Assert-Equal 'refused' (Get-SelfTestVerdict -ExitCode 255 -StdOut '' -StdErr 'someone@127.0.0.1: Permission denied (publickey,keyboard-interactive).') 'verdict: refused (Entra short-name case, seen in the field)'
Assert-Equal 'closed'  (Get-SelfTestVerdict -ExitCode 255 -StdOut '' -StdErr 'Connection closed by 127.0.0.1 port 22') 'verdict: closed (Entra azuread\ case, seen in the field)'
Assert-Equal 'closed'  (Get-SelfTestVerdict -ExitCode 255 -StdOut '' -StdErr 'Connection closed by remote host') 'verdict: closed by remote host'
Assert-Equal 'inconclusive' (Get-SelfTestVerdict -ExitCode 255 -StdOut '' -StdErr 'ssh: connect to host 127.0.0.1 port 22: Connection timed out') 'verdict: timeout is inconclusive'
Assert-Equal 'inconclusive' (Get-SelfTestVerdict -ExitCode 1 -StdOut '' -StdErr '') 'verdict: silent failure is inconclusive'

# ---- Get-ElevationArgs: nothing dropped on the elevated re-launch ------------
$sw = [System.Management.Automation.SwitchParameter]::new($true)
$got = Get-ElevationArgs -ScriptPath 'C:\t\Setup-FleetSSH.ps1' -Bound @{ Persist = $sw; TargetUser = 'bob'; LocalAdmin = 'ops'; AnyRemote = [System.Management.Automation.SwitchParameter]::new($false) }
Assert-Equal @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', '"C:\t\Setup-FleetSSH.ps1"', '-LocalAdmin', '"ops"', '-Persist', '-TargetUser', '"bob"') $got 'elevation: switches and values forwarded, false switches dropped'
Assert-Equal @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', '"x.ps1"') (Get-ElevationArgs -ScriptPath 'x.ps1' -Bound @{}) 'elevation: no parameters'

# ---- Format-DiagnosticPanel: photographable, fixed width ---------------------
$panel = Format-DiagnosticPanel -Title 'FLEET SSH' -Width 40 -Fields ([ordered]@{
    'RESULT' = 'FAIL-REFUSED'
    'sshd log' = @('Invalid user someone from 127.0.0.1 port 50000', 'second line')
    'empty' = @()
})
Assert-Equal 40 (@($panel | ForEach-Object Length | Sort-Object -Unique)) 'panel: every line exactly the width'
Assert-Equal '| RESULT     FAIL-REFUSED              |' $panel[3] 'panel: label/value line'
Assert-Equal '| sshd log   Invalid user someone fro~ |' $panel[4] 'panel: long value cut with ~'
Assert-Equal '|            second line               |' $panel[5] 'panel: continuation line has no label'
Assert-Equal '| empty                                |' $panel[6] 'panel: empty value still shows the label'

Write-Host ""
Write-Host "$($script:Count - $script:Failures)/$($script:Count) passed"
if ($script:Failures) { exit 1 }
