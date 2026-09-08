' Launches Set-BdDayWallpaper.ps1 with no visible console window.
'
' Why this exists: powershell.exe is a console-subsystem program, so Task
' Scheduler launching it directly makes Windows create a console host window
' BEFORE -WindowStyle Hidden can take effect. On Windows 11 that host is
' Windows Terminal (class CASCADIA_HOSTING_WINDOW_CLASS), which ignores the
' hidden window style entirely, giving a ~0.5s flash on every run - every 15
' minutes, plus at logon and unlock.
'
' wscript.exe is a GUI-subsystem program, so it creates no console of its own,
' and WshShell.Run with intWindowStyle 0 starts the child hidden from the
' outset rather than hiding it after the fact.
'
' bWaitOnReturn is True so the task's LastTaskResult still reflects the
' script's real exit code instead of always reporting 0.
'
' Resolves its own directory, so it works wherever the pair is installed.

Option Explicit

Dim fso, shell, scriptDir, psScript, cmd, rc

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psScript = fso.BuildPath(scriptDir, "Set-BdDayWallpaper.ps1")

If Not fso.FileExists(psScript) Then
    WScript.Quit 2
End If

cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & psScript & """"

' Pass through any arguments (e.g. -Restore) given to this launcher.
Dim i
For i = 0 To WScript.Arguments.Count - 1
    cmd = cmd & " " & WScript.Arguments(i)
Next

rc = shell.Run(cmd, 0, True)
WScript.Quit rc
