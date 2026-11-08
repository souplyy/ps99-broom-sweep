Option Explicit
Dim fs, shell, root, python, ahk, script, updater
Set fs = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
root = fs.GetParentFolderName(WScript.ScriptFullName)
python = root & "\runtime\python\pythonw.exe"
ahk = root & "\runtime\AutoHotkey64.exe"
script = root & "\PS99-Broom.ahk"
updater = root & "\updater.py"
shell.CurrentDirectory = root
If Not fs.FileExists(python) Or Not fs.FileExists(ahk) Or Not fs.FileExists(script) Then
  MsgBox "The macro folder is incomplete. Extract the entire ZIP and try again.", 16, "Broom Sweep"
  WScript.Quit 1
End If
' Update before opening, so the active detector files never change mid-round.
If fs.FileExists(updater) Then shell.Run """" & python & """ """ & updater & """", 0, True
shell.Run """" & ahk & """ """ & script & """", 1, False
