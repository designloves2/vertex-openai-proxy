' Launches VertexProxyGui.ps1 with zero visible window, including on
' Windows 11 with "Windows Terminal" set as the default terminal app.
'
' -WindowStyle Hidden on powershell.exe is not enough on such machines:
' Windows 11's default-terminal-app feature intercepts new console
' processes and opens them in a Windows Terminal tab regardless of the
' requested window style. WScript.Shell.Run bypasses that mechanism
' entirely (it isn't a console-hosted launch), so this is the reliable
' way to start a PowerShell script with no window at all.
Dim fso, shell, scriptDir, psPath, logDir, cmd

Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psPath = fso.BuildPath(scriptDir, "VertexProxyGui.ps1")
logDir = scriptDir

Set shell = CreateObject("WScript.Shell")

cmd = "cmd /c powershell.exe -NoLogo -NoProfile -Sta -ExecutionPolicy Bypass -File """ & psPath & """" & _
      " 1> """ & fso.BuildPath(logDir, "launch-stdout.log") & """" & _
      " 2> """ & fso.BuildPath(logDir, "launch-stderr.log") & """"

' 0 = hidden window, False = don't wait for it to finish
shell.Run cmd, 0, False
