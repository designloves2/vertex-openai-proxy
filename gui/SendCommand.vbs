' Writes a one-word command (open / restart / quit) to the ".gui-command"
' file next to this script. The running VertexProxyGui.ps1 instance polls
' that file on its existing DispatcherTimer tick (same timer that already
' polls the Node server's stdout/stderr) and acts on it, then deletes it.
'
' This exists so the Windows taskbar Jump List (right-click the taskbar
' icon) can offer real actions without needing its own IPC mechanism or a
' visible console window — wscript.exe never shows one, unlike invoking
' powershell.exe directly for the same purpose.
Dim fso, scriptDir, cmdPath, ts

If WScript.Arguments.Count < 1 Then
    WScript.Quit 1
End If

Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
cmdPath = fso.BuildPath(scriptDir, ".gui-command")

Set ts = fso.CreateTextFile(cmdPath, True)
ts.Write WScript.Arguments(0)
ts.Close
