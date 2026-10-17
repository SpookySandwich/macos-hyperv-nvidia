# Session-only elevated helper. Handles only named operations on this test VM.
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$request=Join-Path $root 'worker-request.json'
$response=Join-Path $root 'worker-response.json'
$deadline=(Get-Date).AddHours(8)
$lastId=''
$leaveGuestRunning=$false
# A restarted controller must never replay the previous hardware command.
if (Test-Path -LiteralPath $request) {
    try { $lastId=(Get-Content -LiteralPath $request -Raw | ConvertFrom-Json).Id } catch { }
}
Set-Content -LiteralPath (Join-Path $root 'worker-pid.txt') -Value $PID
try { while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $request) {
        try {
            $job=Get-Content -LiteralPath $request -Raw | ConvertFrom-Json
            if ($job.Id -and $job.Id -ne $lastId) {
                $lastId=$job.Id
                if ($job.Action -eq 'Exit') { break }
                if ($job.Action -eq 'FinishSession') {
                    # Explicitly transfer a verified running VM to normal user
                    # control. Timeout/error/ordinary Exit still return the GPU.
                    $gpu=& (Join-Path $root 'gpu-ownership.ps1') -Action GpuInspect
                    if(-not $gpu.AssignedToGuest -or $gpu.VmState -ne 'Running') {
                        throw 'Cannot finish: the expected GPU is not assigned to the running guest.'
                    }
                    $ready=& (Join-Path $root 'wait-guest-graphics.ps1') -TimeoutSeconds 15
                    if(-not $ready.Ready -or -not $ready.FramebufferReady){throw 'Cannot finish: graphics are not ready.'}
                    @{Id=$job.Id;Result=@{Status='Success';Action='FinishSession';VmState='Running';GpuOwner='macOS';AutomaticCleanup=$false}} |
                        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $response
                    $leaveGuestRunning=$true
                    break
                }
                if ($job.Action -notin @('Start','Stop','Inspect','Capture','UpdateBoot','Key','GpuInspect','AssignGpu','ReturnGpu','Nmi','LoginPassword','StartSession','ShutdownAndReturn','PersistBoot','Drag')) { throw 'Unknown operation' }
                if ($job.Action -eq 'Capture') {
                    # Keep any native WMI/GDI failure outside the ownership controller.
                    Remove-Item -LiteralPath (Join-Path $root 'result-Capture.json') -ErrorAction SilentlyContinue
                    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'manage-hyperv.ps1') -Action Capture
                    if ($LASTEXITCODE -ne 0) { throw "Console capture subprocess failed: $LASTEXITCODE" }
                } else {
                    & (Join-Path $root 'manage-hyperv.ps1') -Action $job.Action -KeyCode $job.KeyCode -Path ([string]$job.Path)
                }
                $answer=Get-Content -LiteralPath (Join-Path $root "result-$($job.Action).json") -Raw | ConvertFrom-Json
                @{Id=$job.Id;Result=$answer} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $response
            }
        } catch {
            @{Id=$lastId;Error=$_.Exception.Message} | ConvertTo-Json | Set-Content -LiteralPath $response
        }
    }
    Start-Sleep -Milliseconds 300
} } finally {
    # Recover this exact device when the bounded testing session ends.
    if(-not $leaveGuestRunning) {
        try { & (Join-Path $root 'gpu-ownership.ps1') -Action ReturnGpu -SessionCleanup | Out-Null }
        catch { $_.Exception.Message | Set-Content -LiteralPath (Join-Path $root 'worker-recovery-error.txt') }
    }
    Remove-Item -LiteralPath (Join-Path $root 'worker-pid.txt') -ErrorAction SilentlyContinue
}
