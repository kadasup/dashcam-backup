' run-hidden.vbs - launch a command with no console window at all.
' Used by Windows Task Scheduler so scheduled jobs stop flashing cmd/powershell
' windows on the desktop. Pass the target program and its arguments as separate
' arguments; this script re-quotes any that contain spaces and forwards the exit code.
'
' Example (Task Scheduler action):
'   Program:   wscript.exe
'   Arguments: "<project>\run-hidden.vbs" "D:\path\job.bat"

Option Explicit

Dim sh, i, a, cmd
If WScript.Arguments.Count = 0 Then WScript.Quit 1

cmd = ""
For i = 0 To WScript.Arguments.Count - 1
    a = WScript.Arguments(i)
    If InStr(a, " ") > 0 Then a = """" & a & """"
    If Len(cmd) > 0 Then cmd = cmd & " "
    cmd = cmd & a
Next

Set sh = CreateObject("WScript.Shell")
WScript.Quit sh.Run(cmd, 0, True)
