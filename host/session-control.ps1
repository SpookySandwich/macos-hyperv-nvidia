param([ValidateSet('StartSession','ShutdownAndReturn','PersistBoot')][string]$Action)
$ErrorActionPreference='Stop'
Import-Module Hyper-V
. (Join-Path $PSScriptRoot 'config.ps1')
$name=$Machine.VmName
$vmId=[guid]$Machine.VmId
$root=$PSScriptRoot
$lock=[Threading.Mutex]::new($false,'Local\MacOSHyperVGpuSession')
$acquired=$false
try {
    try { $acquired=$lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired=$true }
    if (-not $acquired) { throw 'Another macOS ownership operation is running.' }
    $vm=Get-VM -Id $vmId
    if ($vm.Name -ne $name) { throw 'VM identity changed.' }
    if ($Action -eq 'PersistBoot') {
        $normal=$Machine.WindowsBootEntry
        $bcdOutput=& bcdedit /enum $normal 2>&1
        if ($LASTEXITCODE) { throw 'Original Windows boot entry is unavailable.' }
        $bcdOutput | Set-Content -LiteralPath (Join-Path $root 'normal-boot-before-iommu.txt')
        & bcdedit /set $normal hypervisoriommupolicy Enable | Out-Null
        if ($LASTEXITCODE) { throw 'Failed to persist the normal-boot IOMMU policy.' }
        & bcdedit /enum $normal | Set-Content -LiteralPath (Join-Path $root 'normal-boot-after-iommu.txt')
        return @{NormalBootIommuPolicy='Enable';WindowsRestarted=$false;NextNormalBootValidationPending=$true}
    }
    $gpu=& (Join-Path $root 'gpu-ownership.ps1') -Action GpuInspect
    if ($Action -eq 'StartSession') {
        if ($vm.State -eq 'Running') {
            if (-not $gpu.AssignedToGuest) { throw 'macOS is running without the 4060. Shut down the guest before starting a GPU session.' }
            $ready=& (Join-Path $root 'wait-guest-graphics.ps1') -TimeoutSeconds 15 -OutputPath (Join-Path $root 'guest-gpu-readiness.json')
            return @{VmState='Running';GpuOwner='macOS';AlreadyRunning=$true;Graphics=$ready}
        }
        if ($vm.State -ne 'Off') { throw "Wait for macOS to finish shutting down (state: $($vm.State))." }
        if (-not $gpu.AssignedToGuest) {
            if ($gpu.Dismounted) { & (Join-Path $root 'gpu-ownership.ps1') -Action ReturnGpu | Out-Null }
            & (Join-Path $root 'gpu-ownership.ps1') -Action AssignGpu | Out-Null
        }
        try {
            & (Join-Path $root 'manage-hyperv.ps1') -Action Start
            $start=Get-Content -LiteralPath (Join-Path $root 'result-Start.json') -Raw | ConvertFrom-Json
            if ($start.Status -ne 'Success') { throw $start.Error }
            # A running Hyper-V VM does not establish guest GPU readiness. The
            # virtual PCI handshake and a real Metal dispatch must both pass.
            $ready=& (Join-Path $root 'wait-guest-graphics.ps1') -TimeoutSeconds 80 -OutputPath (Join-Path $root 'guest-gpu-readiness.json')
        } catch {
            if ((Get-VM -Id $vmId).State -eq 'Off') {
                & (Join-Path $root 'gpu-ownership.ps1') -Action ReturnGpu | Out-Null
            }
            throw
        }
        return @{VmState='Running';GpuOwner='macOS';AlreadyRunning=$false;Graphics=$ready}
    }
    if ($Action -eq 'ShutdownAndReturn') {
        if ($vm.State -eq 'Running') {
            # Guest shutdown integration is installed and verified. Never force
            # power-off here: recovery must not discard unsaved guest work.
            $shutdownJob=Stop-VM -VM $vm -AsJob
        } elseif ($vm.State -notin @('Off','Stopping')) {
            throw "Cannot safely shut down macOS in state $($vm.State)."
        }
        $deadline=(Get-Date).AddSeconds(100)
        while ((Get-VM -Id $vmId).State -ne 'Off') {
            if ($shutdownJob -and $shutdownJob.State -eq 'Failed') { Receive-Job -Job $shutdownJob -ErrorAction Stop; throw 'Hyper-V guest shutdown failed.' }
            if ((Get-Date) -ge $deadline) { throw 'macOS has not shut down. The GPU remains with the guest; no forced power-off was performed.' }
            Start-Sleep -Milliseconds 500
        }
        if ($shutdownJob) { Receive-Job -Job $shutdownJob -Wait -ErrorAction Stop | Out-Null; Remove-Job -Job $shutdownJob }
        & (Join-Path $root 'gpu-ownership.ps1') -Action ReturnGpu | Out-Null
        $hostGpu=@(& nvidia-smi --query-gpu=name,driver_version,memory.used --format=csv,noheader 2>&1)
        if ($LASTEXITCODE -ne 0) { throw 'GPU returned, but the Windows NVIDIA driver readiness check failed.' }
        return @{VmState='Off';GpuOwner='Windows';NvidiaStatus=($hostGpu -join ' ');WindowsBoot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')}
    }
} finally {
    if ($acquired) { $lock.ReleaseMutex() }
    $lock.Dispose()
}
