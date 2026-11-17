Option Explicit
Dim shell, fso, scriptDir, powershell, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
powershell = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
command = """" & powershell & """ -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & scriptDir & "\launch.ps1"""
shell.Run command, 0, False
