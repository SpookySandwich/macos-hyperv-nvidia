param(
    [ValidateSet('GpuInspect','AssignGpu','ReturnGpu')][string]$Action='GpuInspect',
    [switch]$SessionCleanup
)
$ErrorActionPreference='Stop'
Import-Module Hyper-V
. (Join-Path $PSScriptRoot 'config.ps1')
$vmName=$Machine.VmName
$vmId=[guid]$Machine.VmId
$gpuId=$Machine.GpuInstanceId
$location=$Machine.GpuLocationPath
$statePath=Join-Path $PSScriptRoot 'gpu-ownership-state.json'
$logPath=Join-Path $PSScriptRoot 'gpu-ownership-events.jsonl'
$ownershipLock=[Threading.Mutex]::new($false,'Local\MacOSHyperVGpuSession')
$ownershipAcquired=$false
try {
try { $ownershipAcquired=$ownershipLock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownershipAcquired=$true }
if (-not $ownershipAcquired) { throw 'Another macOS GPU operation is running.' }
$vm=Get-VM -Id $vmId
if ($vm.Name -ne $vmName) { throw 'The macOS VM identity changed.' }
function Record([string]$phase) {
    $record=[ordered]@{Timestamp=(Get-Date).ToString('o');Phase=$phase;GpuId=$gpuId;LocationPath=$location;VmId=$vmId.ToString();WindowsBoot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')}
    $json=$record | ConvertTo-Json -Compress
    $json | Set-Content -LiteralPath "$statePath.new"
    Move-Item -LiteralPath "$statePath.new" -Destination $statePath -Force
    $json | Add-Content -LiteralPath $logPath
}
function Assigned { @(Get-VMAssignableDevice -VMName $vmName | Where-Object LocationPath -eq $location) }
function Available { @(Get-VMHostAssignableDevice | Where-Object LocationPath -eq $location) }
function Restore {
    if ((Assigned).Count) {
        if ((Get-VM -Id $vmId).State -ne 'Off') { throw 'Gracefully shut down macOS before returning its GPU.' }
        Remove-VMAssignableDevice -VMName $vmName -LocationPath $location
        Record 'RemovedFromGuest'
    }
    if ((Available).Count) { Mount-VMHostAssignableDevice -LocationPath $location; Record 'MountedToWindows' }
    $problem=(Get-PnpDeviceProperty -InstanceId $gpuId -KeyName DEVPKEY_Device_ProblemCode).Data
    if ($problem -eq 22) { Enable-PnpDevice -InstanceId $gpuId -Confirm:$false }
    for ($i=0; $i -lt 20; $i++) {
        $problem=(Get-PnpDeviceProperty -InstanceId $gpuId -KeyName DEVPKEY_Device_ProblemCode).Data
        if ($problem -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }
    if ($problem -ne 0) { Record 'RecoveryRequired'; throw "GPU returned with Windows problem code $problem." }
    Record 'WindowsOwnsGpu'
}
if ($Action -eq 'AssignGpu') {
    if ($vm.State -ne 'Off') { throw 'The guest must be fully shut down before GPU assignment.' }
    if ((Assigned).Count) { throw 'GPU already belongs to this VM.' }
    if ((Available).Count) { throw 'GPU is already dismounted; recover its existing state first.' }
    $gpu=Get-PnpDevice -InstanceId $gpuId
    if ($gpu.Status -ne 'OK' -or $gpu.FriendlyName -ne $Machine.GpuFriendlyName) { throw 'Exact NVIDIA GPU is not healthy.' }
    if (@((Get-PnpDeviceProperty -InstanceId $gpuId -KeyName DEVPKEY_Device_LocationPaths).Data) -notcontains $location) { throw 'GPU PCI location changed.' }
    $intel=Get-CimInstance Win32_VideoController | Where-Object { $_.Name -eq $Machine.HostDisplayAdapter -and $_.ConfigManagerErrorCode -eq 0 -and $_.CurrentHorizontalResolution -gt 0 }
    if (-not $intel) { throw 'Active Intel display route could not be verified.' }
    for ($idleAttempt=0; $idleAttempt -lt 10; $idleAttempt++) {
        $usage=@(& nvidia-smi --query-gpu=display_active,memory.used --format=csv,noheader,nounits 2>&1)
        if ($LASTEXITCODE -ne 0 -or ($usage -join '').Trim() -match '^Disabled,\s*0$') { break }
        Start-Sleep -Milliseconds 500
    }
    if ($LASTEXITCODE -ne 0 -or ($usage -join '').Trim() -notmatch '^Disabled,\s*0$') { throw 'NVIDIA display or GPU memory is in use; close GPU applications before transfer.' }
    if (Get-Process -Name qemu-system-x86_64 -ErrorAction SilentlyContinue) { throw 'QEMU is still running.' }
    if (-not (Get-VMHost).IovSupport) { throw 'I/O virtualization is unavailable in this Windows boot.' }
    Record 'Assigning'
    try {
        Set-VM -VM $vm -AutomaticStopAction TurnOff -GuestControlledCacheTypes $true -LowMemoryMappedIoSpace 3GB -HighMemoryMappedIoSpace 32GB
        Disable-PnpDevice -InstanceId $gpuId -Confirm:$false
        Record 'DisabledInWindows'
        Dismount-VMHostAssignableDevice -LocationPath $location -Force
        Record 'DismountedFromWindows'
        Add-VMAssignableDevice -VMName $vmName -LocationPath $location
        if ((Assigned).Count -ne 1) { throw 'Hyper-V did not report the GPU assignment.' }
        Record 'GuestOwnsGpu'
    } catch {
        $assignmentError=$_.Exception.Message
        try { Restore } catch { throw "Assignment failed: $assignmentError. Recovery failed: $($_.Exception.Message)" }
        throw "Assignment failed; GPU restored: $assignmentError"
    }
}
if ($Action -eq 'ReturnGpu') {
    if ($SessionCleanup -and -not (Assigned).Count -and -not (Available).Count) { return }
    if ($SessionCleanup -and (Assigned).Count -and (Get-VM -Id $vmId).State -ne 'Off') {
        # A vanished testing controller must not leave Windows without its GPU.
        try { Stop-VM -Name $vmName -ErrorAction Stop } catch { }
        if ((Get-VM -Id $vmId).State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force }
    }
    Restore
}
[ordered]@{AssignedToGuest=((Assigned).Count -eq 1);Dismounted=((Available).Count -eq 1);VmState=(Get-VM -Id $vmId).State.ToString();WindowsGpuStatus=(Get-PnpDevice -InstanceId $gpuId).Status;WindowsProblemCode=(Get-PnpDeviceProperty -InstanceId $gpuId -KeyName DEVPKEY_Device_ProblemCode).Data}
} finally {
    if ($ownershipAcquired) { $ownershipLock.ReleaseMutex() }
    $ownershipLock.Dispose()
}
