param([ValidateSet('Inspect','Assign','Start','Shutdown','Return','Unlock','WakeSignIn')][string]$Action)
$ErrorActionPreference='Stop'
Import-Module Hyper-V
# Machine identities come from machine.json (copied next to this script at build time).
$machine=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'machine.json') -Raw | ConvertFrom-Json
$vmId=[guid]$machine.VmId
$gpuId=$machine.GpuInstanceId
$location=$machine.GpuLocationPath
$vm=Get-VM -Id $vmId
if($vm.Name -ne $machine.VmName){throw 'VM identity changed.'}
function Assigned { @(Get-VMAssignableDevice -VM $vm | Where-Object LocationPath -eq $location) }
function Available { @(Get-VMHostAssignableDevice | Where-Object LocationPath -eq $location) }
function RestoreGpu {
    if((Get-VM -Id $vmId).State -ne 'Off'){throw 'macOS must be fully shut down before returning its GPU.'}
    if((Assigned).Count){Remove-VMAssignableDevice -VMName $vm.Name -LocationPath $location}
    if((Available).Count){Mount-VMHostAssignableDevice -LocationPath $location}
    if((Get-PnpDeviceProperty -InstanceId $gpuId -KeyName DEVPKEY_Device_ProblemCode).Data -eq 22){Enable-PnpDevice -InstanceId $gpuId -Confirm:$false}
    for($n=0;$n -lt 30;$n++){
        if((Get-PnpDeviceProperty -InstanceId $gpuId -KeyName DEVPKEY_Device_ProblemCode).Data -eq 0){return}
        Start-Sleep -Milliseconds 500
    }
    throw 'The Windows NVIDIA driver has not become ready.'
}
if($Action -eq 'Inspect'){
    $ip=@(Get-VMNetworkAdapter -VM $vm | ForEach-Object IPAddresses | Where-Object {$_ -match '^\d+\.\d+\.\d+\.\d+$'} | Select-Object -First 1)
    if(-not $ip){$ip=@(Get-NetNeighbor -AddressFamily IPv4 | Where-Object {$_.InterfaceAlias -like "*$($machine.VirtualSwitch)*" -and $_.LinkLayerAddress -eq $machine.GuestMac} | Select-Object -ExpandProperty IPAddress -First 1)}
    $video=Get-VMVideo -VM $vm
    [ordered]@{VmState=$vm.State.ToString();GpuAssigned=((Assigned).Count -eq 1);GpuAvailable=((Available).Count -eq 1);HostHealthy=((Get-PnpDeviceProperty -InstanceId $gpuId -KeyName DEVPKEY_Device_ProblemCode).Data -eq 0);Address=$(if($ip){[string]$ip[0]}else{$null});Video=[ordered]@{ResolutionType=$video.ResolutionType.ToString();HorizontalResolution=$video.HorizontalResolution;VerticalResolution=$video.VerticalResolution}} | ConvertTo-Json -Depth 3 -Compress
    return
}
$mutex=[Threading.Mutex]::new($false,'Global\MacOSHyperVGpuSession')
$held=$false
try {
    try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
    if(-not $held){throw 'Another GPU ownership operation is running.'}
    switch($Action){
        WakeSignIn {
            if($vm.State -ne 'Running' -or (Assigned).Count -ne 1){throw 'A running macOS GPU session is required.'}
            $system=Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_ComputerSystem -Filter "Name='$vmId'"
            $keyboard=Get-CimAssociatedInstance -InputObject $system -ResultClassName Msvm_Keyboard
            # The client has rechecked the locked guest-user session. This only
            # exposes the sign-in UI; it never reads or submits a credential.
            $wake=Invoke-CimMethod -InputObject $keyboard -MethodName TypeKey -Arguments @{KeyCode=[uint32]13}
            if($wake.ReturnValue -ne 0){throw 'Sign-in screen wake failed.'}
        }
        Unlock {
            if($vm.State -ne 'Running' -or (Assigned).Count -ne 1){throw 'A running macOS GPU session is required.'}
            [Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
            $secret=[Console]::ReadLine()
            if([string]::IsNullOrEmpty($secret) -or $secret.Length -gt 512){throw 'Sign-in credential unavailable.'}
            try{
                $system=Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_ComputerSystem -Filter "Name='$vmId'"
                $keyboard=Get-CimAssociatedInstance -InputObject $system -ResultClassName Msvm_Keyboard
                # The guest readiness probe has already verified that
                # loginwindow owns secure keyboard input. Do not substitute
                # an arbitrary wake delay for password-field readiness.
                # macOS can retain a failed/partially entered password. Clear
                # the secure field first, and pace input through the virtual
                # keyboard rather than flooding its synthetic event queue.
                $pressed=Invoke-CimMethod -InputObject $keyboard -MethodName PressKey -Arguments @{KeyCode=[uint32]91}
                try {
                    $selected=Invoke-CimMethod -InputObject $keyboard -MethodName TypeKey -Arguments @{KeyCode=[uint32]65}
                } finally {
                    $released=Invoke-CimMethod -InputObject $keyboard -MethodName ReleaseKey -Arguments @{KeyCode=[uint32]91}
                }
                $cleared=Invoke-CimMethod -InputObject $keyboard -MethodName TypeKey -Arguments @{KeyCode=[uint32]8}
                if($pressed.ReturnValue -ne 0 -or $selected.ReturnValue -ne 0 -or $released.ReturnValue -ne 0 -or $cleared.ReturnValue -ne 0){throw 'Secure field input failed.'}
                foreach($character in $secret.ToCharArray()) {
                    $typed=Invoke-CimMethod -InputObject $keyboard -MethodName TypeText -Arguments @{AsciiText=[string]$character}
                    if($typed.ReturnValue -ne 0){throw 'Sign-in input failed.'}
                    Start-Sleep -Milliseconds 35
                }
                $character=$null
                $enter=Invoke-CimMethod -InputObject $keyboard -MethodName TypeKey -Arguments @{KeyCode=[uint32]13}
                if($enter.ReturnValue -ne 0){throw 'Sign-in submit failed.'}
            }catch{throw 'macOS sign-in input failed.'}finally{$secret=$null}
        }
        Assign {
            if($vm.State -ne 'Off'){throw 'macOS must be off before assigning the 4060.'}
            if((Assigned).Count){return}
            if((Available).Count){RestoreGpu}
            # Qualify the host's larger console aperture before enabling native
            # guest modes. This changes only this VM, while it is fully off.
            $videoBefore=Get-VMVideo -VM $vm
            if($videoBefore.ResolutionType.ToString() -ne 'Single' -or $videoBefore.HorizontalResolution -ne 3200 -or $videoBefore.VerticalResolution -ne 2000){
                try {
                    Set-VMVideo -VM $vm -ResolutionType Single -HorizontalResolution 3200 -VerticalResolution 2000
                    $videoAfter=Get-VMVideo -VM $vm
                    if($videoAfter.ResolutionType.ToString() -ne 'Single' -or $videoAfter.HorizontalResolution -ne 3200 -or $videoAfter.VerticalResolution -ne 2000){throw 'Hyper-V did not confirm console video capacity.'}
                } catch {
                    Set-VMVideo -VM $vm -ResolutionType $videoBefore.ResolutionType -HorizontalResolution $videoBefore.HorizontalResolution -VerticalResolution $videoBefore.VerticalResolution
                    throw
                }
            }
            $gpu=Get-PnpDevice -InstanceId $gpuId
            if($gpu.Status -ne 'OK' -or $gpu.FriendlyName -ne $machine.GpuFriendlyName){throw 'The expected RTX 4060 is not ready.'}
            if(@((Get-PnpDeviceProperty -InstanceId $gpuId -KeyName DEVPKEY_Device_LocationPaths).Data) -notcontains $location){throw 'GPU PCI location changed.'}
            $intel=Get-CimInstance Win32_VideoController | Where-Object {$_.Name -eq $machine.HostDisplayAdapter -and $_.ConfigManagerErrorCode -eq 0 -and $_.CurrentHorizontalResolution -gt 0}
            if(-not $intel){throw 'The Intel display is not active.'}
            $usage=@(& "$env:SystemRoot\System32\nvidia-smi.exe" --query-gpu=display_active,memory.used --format=csv,noheader,nounits 2>&1)
            if($LASTEXITCODE -ne 0 -or ($usage -join '').Trim() -notmatch '^Disabled,\s*0$'){throw 'Close Windows apps using the 4060, then try again.'}
            if(-not (Get-VMHost).IovSupport){throw 'I/O virtualization is unavailable in this Windows boot.'}
            try{
                Disable-PnpDevice -InstanceId $gpuId -Confirm:$false
                Dismount-VMHostAssignableDevice -LocationPath $location -Force
                Add-VMAssignableDevice -VM $vm -LocationPath $location
                if((Assigned).Count -ne 1){throw 'Hyper-V did not confirm GPU assignment.'}
            }catch{
                $original=$_.Exception.Message
                try{RestoreGpu}catch{throw "GPU assignment failed: $original. Recovery: $($_.Exception.Message)"}
                throw "GPU assignment failed; the 4060 was returned to Windows: $original"
            }
        }
        Start {
            if((Get-VM -Id $vmId).State -ne 'Off' -or (Assigned).Count -ne 1){throw 'macOS must be off with its GPU assigned before starting.'}
            # An archived VM keeps its disks NTFS-compressed; Hyper-V only attaches uncompressed disks, and
            # decompressing takes longer than this action may run.
            foreach($disk in @(Get-VMHardDiskDrive -VM $vm | ForEach-Object Path)){
                if((Get-Item -LiteralPath $disk).Attributes -band [IO.FileAttributes]::Compressed){
                    throw 'The VM disks are NTFS-compressed. Decompress them once (compact.exe /u), then start again.'
                }
            }
            Start-VM -VM $vm | Out-Null
        }
        Shutdown {
            if($vm.State -eq 'Running'){$job=Stop-VM -VM $vm -AsJob}
            elseif($vm.State -notin @('Stopping','Off')){throw 'macOS cannot shut down safely in its current state.'}
            $limit=(Get-Date).AddSeconds(110)
            while((Get-VM -Id $vmId).State -ne 'Off'){
                if($job -and $job.State -eq 'Failed'){Receive-Job $job -ErrorAction Stop; throw 'Guest shutdown failed.'}
                if((Get-Date) -ge $limit){throw 'macOS has not shut down. Save your work and shut down from the Apple menu; the GPU has been left assigned.'}
                Start-Sleep -Milliseconds 500
            }
            if($job){Receive-Job $job -Wait -ErrorAction Stop | Out-Null; Remove-Job $job}
        }
        Return { RestoreGpu }
    }
}finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
