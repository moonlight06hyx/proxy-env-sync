' run-hidden.vbs - run a PowerShell script with no console window at all.
'
' wscript.exe is a GUI-subsystem program, so Windows never allocates a console
' for it. Routing the shortcut through here means no terminal flashes when
' Antigravity starts.
'
' Usage: wscript.exe run-hidden.vbs "C:\path\to\launch-antigravity.ps1"

Dim shell, scriptPath
If WScript.Arguments.Count < 1 Then
  WScript.Quit 2
End If

scriptPath = WScript.Arguments(0)
Set shell = CreateObject("WScript.Shell")
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptPath & """", 0, False
