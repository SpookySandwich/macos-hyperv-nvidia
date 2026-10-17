$ErrorActionPreference='Stop'
$script=Join-Path $PSScriptRoot 'testing-worker.ps1'
$process=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -WindowStyle Hidden `
    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$script+'"')) -PassThru
Write-Output "Administrative helper running: $($process.Id)"
# Keep this terminal session alive; otherwise its child helper is cleaned up.
$process.WaitForExit()
Write-Output "Administrative helper exited: $($process.ExitCode)"
