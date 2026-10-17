# One UAC approval that extends the elevated testing window: waits for the
# current worker (worker-pid.txt) to exit, then runs a fresh 2-hour worker.
# The controller ends the old worker with FinishSession so macOS keeps its GPU.
param([switch]$Elevated)
$ErrorActionPreference='Stop'
if(-not $Elevated){
    $process=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -WindowStyle Hidden `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'),'-Elevated') -PassThru
    Write-Output "Extension helper running: $($process.Id)"
    $process.WaitForExit()
    Write-Output "Extension helper exited: $($process.ExitCode)"
    return
}
$log=Join-Path $PSScriptRoot 'approve-session.log'
function Note($m){ Add-Content -LiteralPath $log -Value "$((Get-Date).ToString('o')) $m" }
Note 'extension approved; waiting for current worker'
$pidFile=Join-Path $PSScriptRoot 'worker-pid.txt'
$old=$null
if(Test-Path -LiteralPath $pidFile){ $old=[int](Get-Content -LiteralPath $pidFile -Raw).Trim() }
if($old){ try { (Get-Process -Id $old -ErrorAction Stop).WaitForExit() } catch { } }
Start-Sleep -Seconds 2
Note 'extension worker starting'
& (Join-Path $PSScriptRoot 'testing-worker.ps1')
Note 'extension worker exited'
