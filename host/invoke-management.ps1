param([Parameter(Mandatory)][string]$Action,[int]$KeyCode=13)
$ErrorActionPreference='Stop'
$script=Join-Path $PSScriptRoot 'manage-hyperv.ps1'
$requestId=[guid]::NewGuid()
$result=Join-Path $PSScriptRoot "result-$Action-$requestId.json"
$process=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -WindowStyle Hidden `
    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$script+'"'),'-Action',$Action,'-KeyCode',"$KeyCode",'-RequestId',$requestId.ToString()) -PassThru
$process.WaitForExit()
if (Test-Path -LiteralPath $result) {
    $answer=Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
    if ($answer.Status -ne 'Success') { throw $answer.Error }
    $answer
}
else { throw "Management process exited $($process.ExitCode) without a result." }
