param([Parameter(Mandatory)][string]$Action,[int]$KeyCode=13,[string]$Path='',[ValidateRange(1,300)][int]$TimeoutSeconds=55)
$ErrorActionPreference='Stop'
$id=[guid]::NewGuid().ToString()
$request=Join-Path $PSScriptRoot 'worker-request.json'
$response=Join-Path $PSScriptRoot 'worker-response.json'
$clientLock=[Threading.Mutex]::new($false,'Local\MacOSHyperVTestingClient')
$clientAcquired=$false
try {
try { $clientAcquired=$clientLock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $clientAcquired=$true }
if(-not $clientAcquired){throw 'A testing request is already running.'}
$staging="$request.$id.new"
@{Id=$id;Action=$Action;KeyCode=$KeyCode;Path=$Path} | ConvertTo-Json | Set-Content -LiteralPath $staging
$replaceDeadline=(Get-Date).AddSeconds(3)
while($true){
    try {
        if(Test-Path -LiteralPath $request){[IO.File]::Replace($staging,$request,[NullString]::Value)}else{[IO.File]::Move($staging,$request)}
        break
    } catch [IO.IOException] {
        if((Get-Date) -ge $replaceDeadline){throw}
        Start-Sleep -Milliseconds 75
    }
}
if ($Action -eq 'Exit') { return }
$deadline=(Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $response) {
        $answer=$null
        try {
            $answer=Get-Content -LiteralPath $response -Raw | ConvertFrom-Json
        } catch { }
        if ($answer -and $answer.Id -eq $id) {
            $answer | ConvertTo-Json -Depth 10
            if ($answer.Error) { throw $answer.Error }
            if ($answer.Result.Status -eq 'Failed') { throw $answer.Result.Error }
            return
        }
    }
    Start-Sleep -Milliseconds 300
}
throw "No response to $Action within $TimeoutSeconds seconds."
} finally {
    if($clientAcquired){$clientLock.ReleaseMutex()}
    $clientLock.Dispose()
}
