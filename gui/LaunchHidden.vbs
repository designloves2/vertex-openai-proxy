' Launches VertexProxyGui.ps1 with zero visible window, including on
' Windows 11 with "Windows Terminal" set as the default terminal app.
'
' -WindowStyle Hidden on powershell.exe is not enough on such machines:
' Windows 11's default-terminal-app feature intercepts new console
' processes and opens them in a Windows Terminal tab regardless of the
' requested window style. WScript.Shell.Run bypasses that mechanism
' entirely (it isn't a console-hosted launch), so this is the reliable
' way to start a PowerShell script with no window at all.
Dim fso, shell, scriptDir, psPath, logDir, cmd, stamp, stdoutPath, stderrPath

Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psPath = fso.BuildPath(scriptDir, "VertexProxyGui.ps1")
logDir = scriptDir

Set shell = CreateObject("WScript.Shell")

' A fixed log filename can get stuck locked by something else (AV/EDR
' real-time scan, a lingering handle from a killed prior run, ...) with no
' visible owning process to kill — and cmd.exe's own "1> file" redirection
' then fails to even open it, which means powershell.exe (the actual GUI)
' never launches at all: total silent failure, indistinguishable from the
' app just not existing. A timestamp-qualified name sidesteps this
' entirely — nothing else contending for it. Randomize() + Rnd guards
' against two launches in the same second colliding.
Randomize
stamp = Year(Now) & Right("0" & Month(Now), 2) & Right("0" & Day(Now), 2) & "-" & _
        Right("0" & Hour(Now), 2) & Right("0" & Minute(Now), 2) & Right("0" & Second(Now), 2) & _
        "-" & Int(Rnd * 10000)
stdoutPath = fso.BuildPath(logDir, "launch-stdout-" & stamp & ".log")
stderrPath = fso.BuildPath(logDir, "launch-stderr-" & stamp & ".log")

cmd = "cmd /c powershell.exe -NoLogo -NoProfile -Sta -ExecutionPolicy Bypass -File """ & psPath & """" & _
      " 1> """ & stdoutPath & """" & _
      " 2> """ & stderrPath & """"

' 0 = hidden window, False = don't wait for it to finish
shell.Run cmd, 0, False

' Best-effort cleanup so timestamped logs don't accumulate forever. Any
' still-locked leftover simply fails to delete and is skipped — never
' worth blocking or failing the actual launch over.
On Error Resume Next
Dim f, folder
Set folder = fso.GetFolder(logDir)
For Each f In folder.Files
    If (InStr(f.Name, "launch-stdout-") = 1 Or InStr(f.Name, "launch-stderr-") = 1) _
       And DateDiff("d", f.DateLastModified, Now) >= 1 Then
        fso.DeleteFile f.Path, True
    End If
Next
On Error Goto 0
