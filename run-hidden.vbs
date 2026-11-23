' run-hidden.vbs - run a PowerShell script with no console window at all.
'
' wscript.exe is a GUI-subsystem program, so Windows never allocates a console
' for it. Routing the shortcut through here means no terminal flashes when
' Antigravity starts.
'
' Usage: wscript.exe run-hidden.vbs "C:\path\to\launch-antigravity.ps1" ["-RepairOnly"]

Dim shell, scriptPath, extra, i
If WScript.Arguments.Count < 1 Then
  WScript.Quit 2
End If

scriptPath = WScript.Arguments(0)
extra = ""
For i = 1 To WScript.Arguments.Count - 1
  extra = extra & " " & WScript.Arguments(i)
Next

Set shell = CreateObject("WScript.Shell")
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptPath & """" & extra, 0, False
