<#
.SYNOPSIS
    Installs (or removes) the BdDay-Wallpaper scheduled task on a Windows host.

.DESCRIPTION
    Set-BdDayWallpaper.ps1 must run inside the user's INTERACTIVE session: an
    SSH session gets its own non-interactive window station, where
    SystemParametersInfo cannot touch the logged-on desktop. A scheduled task
    with an InteractiveToken principal is what bridges that gap, so this is the
    supported way to drive the wallpaper from a remote fleet host.

    The task runs at logon, on session unlock, and every 15 minutes. It runs at
    LeastPrivilege as the ordinary user - setting a wallpaper needs no
    elevation, and the script only writes under %LOCALAPPDATA% and HKCU.

    Deploy the payload script alongside this one, then run this with -Install.

.PARAMETER Install
    Copy the script into place and register the scheduled task.

.PARAMETER Uninstall
    Restore the original wallpaper, unregister the task, and remove the
    installed script. Leaves the state directory (and its log) in place.

.PARAMETER SourceScript
    Path to Set-BdDayWallpaper.ps1 to install. Defaults to the copy sitting
    next to this installer.

.PARAMETER RunNow
    After installing, start the task immediately so the wallpaper applies
    without waiting for a trigger.
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')][switch]$Install,
    [Parameter(ParameterSetName = 'Uninstall')][switch]$Uninstall,
    [Parameter(ParameterSetName = 'Install')][string]$SourceScript,
    [Parameter(ParameterSetName = 'Install')][switch]$RunNow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName = 'BdDay-Wallpaper'
# Registered alongside the main task with no triggers, purely so that a remote
# operator can roll back. Calling the script with -Restore over SSH would write
# the registry value but never reach the interactive desktop; starting an
# on-demand task with an InteractiveToken principal does.
$RestoreTaskName = 'BdDay-Wallpaper-Restore'
$InstallDir = Join-Path $env:USERPROFILE 'bdday-wallpaper'
$InstalledScript = Join-Path $InstallDir 'Set-BdDayWallpaper.ps1'

# NOT "$env:USERDOMAIN\$env:USERNAME". On this workgroup-joined laptop
# USERDOMAIN is "WORKGROUP", and Register-ScheduledTask then fails with
# "No mapping between account names and security IDs was done" (0x80070534).
# The authenticated identity gives the real principal (MACHINE\user, or
# DOMAIN\user on a joined machine).
$Account = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

if ($Uninstall) {
    $restoreTask = Get-ScheduledTask -TaskName $RestoreTaskName -ErrorAction SilentlyContinue
    if ($restoreTask -and (Test-Path $InstalledScript)) {
        Write-Output 'Restoring the original wallpaper in the interactive session...'
        Start-ScheduledTask -TaskName $RestoreTaskName
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Seconds 2
            if ((Get-ScheduledTask -TaskName $RestoreTaskName).State -ne 'Running') { break }
        }
        $rr = Get-ScheduledTaskInfo -TaskName $RestoreTaskName
        Write-Output "Restore task result = $($rr.LastTaskResult) (0 = success)"
    } else {
        Write-Warning 'Restore task or installed script missing; skipping wallpaper restore.'
    }

    foreach ($t in @($TaskName, $RestoreTaskName)) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $t -Confirm:$false
            Write-Output "Unregistered scheduled task '$t'."
        } else {
            Write-Output "Scheduled task '$t' was not registered."
        }
    }
    if (Test-Path $InstalledScript) {
        Remove-Item $InstalledScript -Force
        Write-Output "Removed $InstalledScript"
    }
    # PowerShell has already read this file into memory, so removing the
    # installed copy of the installer while it runs is safe. Tolerate failure -
    # it must never block the rest of the teardown.
    $selfCopy = Join-Path $InstallDir 'Install-BdDayWallpaper.ps1'
    if (Test-Path $selfCopy) {
        try { Remove-Item $selfCopy -Force; Write-Output "Removed $selfCopy" }
        catch { Write-Warning "Could not remove $selfCopy : $($_.Exception.Message)" }
    }
    if ((Test-Path $InstallDir) -and -not (Get-ChildItem $InstallDir -Force)) {
        try { Remove-Item $InstallDir -Force; Write-Output "Removed empty $InstallDir" } catch { }
    }
    Write-Output 'Done. State and log left under %LOCALAPPDATA%\bdday-wallpaper.'
    exit 0
}

if (-not $SourceScript) {
    $SourceScript = Join-Path $PSScriptRoot 'Set-BdDayWallpaper.ps1'
}
if (-not (Test-Path $SourceScript)) {
    throw "Source script not found: $SourceScript"
}

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
Copy-Item -Path $SourceScript -Destination $InstalledScript -Force
Write-Output "Installed $InstalledScript"

# Install a copy of THIS script beside the payload, so removal is self-contained
# on the machine and does not require fetching the repo again. Without this,
# the documented "-Uninstall" has nothing to run.
$InstalledInstaller = Join-Path $InstallDir 'Install-BdDayWallpaper.ps1'
if ($PSCommandPath -and ($PSCommandPath -ne $InstalledInstaller)) {
    Copy-Item -Path $PSCommandPath -Destination $InstalledInstaller -Force
    Write-Output "Installed $InstalledInstaller"
}

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Sets the desktop wallpaper to the current Cullen biodynamic day (bd.ablz.au). Managed from nixosconfig: tools/windows/Set-BdDayWallpaper.ps1</Description>
    <URI>\$TaskName</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$Account</UserId>
      <Delay>PT30S</Delay>
    </LogonTrigger>
    <CalendarTrigger>
      <StartBoundary>2026-01-01T00:03:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
      <Repetition>
        <Interval>PT15M</Interval>
        <Duration>P1D</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </CalendarTrigger>
    <SessionStateChangeTrigger>
      <Enabled>true</Enabled>
      <UserId>$Account</UserId>
      <StateChange>SessionUnlock</StateChange>
      <Delay>PT5S</Delay>
    </SessionStateChangeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$Account</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$InstalledScript"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force | Out-Null
Write-Output "Registered scheduled task '$TaskName' for $Account (logon + unlock + every 15 min)."

$restoreXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>On-demand rollback for BdDay-Wallpaper: restores the wallpaper recorded before it was first applied. No triggers; started manually or by Install-BdDayWallpaper.ps1 -Uninstall.</Description>
    <URI>\$RestoreTaskName</URI>
  </RegistrationInfo>
  <Triggers />
  <Principals>
    <Principal id="Author">
      <UserId>$Account</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$InstalledScript" -Restore</Arguments>
    </Exec>
  </Actions>
</Task>
"@

Register-ScheduledTask -TaskName $RestoreTaskName -Xml $restoreXml -Force | Out-Null
Write-Output "Registered on-demand rollback task '$RestoreTaskName'."

if ($RunNow) {
    Start-ScheduledTask -TaskName $TaskName
    Write-Output 'Started the task; waiting for it to finish...'
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 2
        $info = Get-ScheduledTask -TaskName $TaskName
        if ($info.State -ne 'Running') { break }
    }
    $result = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Output "LastTaskResult = $($result.LastTaskResult) (0 = success)"
    Write-Output "LastRunTime    = $($result.LastRunTime)"
}
