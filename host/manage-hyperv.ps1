param(
    [ValidateSet('Setup','Start','Stop','Inspect','Capture','UpdateBoot','Key','GpuInspect','AssignGpu','ReturnGpu','Nmi','LoginPassword','StartSession','ShutdownAndReturn','PersistBoot','Drag')]
    [string]$Action = 'Inspect',
    [int]$KeyCode = 13,
    [string]$Path = '',
    [guid]$RequestId = [guid]::Empty
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $PSScriptRoot 'config.ps1')
$name = $Machine.VmName
$result = [ordered]@{ Action=$Action; Timestamp=(Get-Date).ToString('o'); Status='Running' }
$out = Join-Path $root "result-$Action.json"
if ($RequestId -ne [guid]::Empty) { $out=Join-Path $root "result-$Action-$RequestId.json" }
try {
    Import-Module Hyper-V
    if ($Action -in 'StartSession','ShutdownAndReturn','PersistBoot') {
        $result.Session = & (Join-Path $root 'session-control.ps1') -Action $Action
    }
    if ($Action -in 'GpuInspect','AssignGpu','ReturnGpu') {
        $result.Gpu = & (Join-Path $root 'gpu-ownership.ps1') -Action $Action
    }
    if ($Action -eq 'Setup') {
        if (Get-VM -Name $name -ErrorAction SilentlyContinue) { throw 'VM already exists; inspect instead of recreating.' }
        $bootPath = Join-Path $Machine.VmDirectory 'OpenCore.vhdx'
        if (Test-Path -LiteralPath $bootPath) { throw 'Boot disk already exists.' }
        New-VHD -Path $bootPath -Dynamic -SizeBytes 512MB | Out-Null
        try {
            $disk = Mount-VHD -Path $bootPath -PassThru | Get-Disk
            $part = $disk | Initialize-Disk -PartitionStyle GPT -PassThru |
                New-Partition -UseMaximumSize -AssignDriveLetter -GptType '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
            $vol = $part | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'HVBOOT' -Confirm:$false -Force
            foreach ($item in 'EFI','Scripts','Tools') {
                Copy-Item -LiteralPath (Join-Path $root "boot-source\$item") -Destination "$($vol.DriveLetter):\$item" -Recurse -Force
            }
        } finally { Dismount-VHD -Path $bootPath -ErrorAction SilentlyContinue }
        $vm = New-VM -Name $name -Generation 2 -NoVHD -Path (Join-Path $Machine.VmDirectory 'machine') -MemoryStartupBytes 6GB
        Set-VM -VM $vm -ProcessorCount 4 -AutomaticCheckpointsEnabled $false -CheckpointType Disabled `
            -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -GuestControlledCacheTypes $true `
            -LowMemoryMappedIoSpace 3GB -HighMemoryMappedIoSpace 32GB
        Set-VMMemory -VMName $name -DynamicMemoryEnabled $false
        Add-VMHardDiskDrive -VMName $name -Path $bootPath -ControllerType SCSI -ControllerLocation 0
        Add-VMHardDiskDrive -VMName $name -Path (Join-Path $Machine.VmDirectory 'macOS.vhdx') -ControllerType SCSI -ControllerLocation 1
        $efi = Get-VMHardDiskDrive -VMName $name | Where-Object ControllerLocation -eq 0
        Set-VMFirmware -VMName $name -EnableSecureBoot Off -FirstBootDevice $efi
        Connect-VMNetworkAdapter -VMName $name -SwitchName $Machine.VirtualSwitch
        $mac = $Machine.GuestMac -replace '-',''
        Set-VMNetworkAdapter -VMName $name -StaticMacAddress $mac
        Enable-VMIntegrationService -VMName $name -Name 'Guest Service Interface'
    }
    if ($Action -eq 'Start') {
        if ((Get-VM -Name $name).State -ne 'Off') { throw 'Wait for a complete guest shutdown before changing CPU configuration.' }
        $settings=Get-Content -LiteralPath (Join-Path $root 'vm-settings.json') -Raw | ConvertFrom-Json
        if ($settings.ProcessorCount -lt 1 -or $settings.ProcessorCount -gt 16) { throw 'Invalid CPU count.' }
        Set-VMProcessor -VMName $name -Count $settings.ProcessorCount -HwThreadCountPerCore 1
        if ($settings.SerialDebug) {
            Set-VMComPort -VMName $name -Number 1 -Path '\\.\pipe\macOS-HyperV-com1'
        }
        if ($settings.ConsoleHD) {
            Set-VMVideo -VMName $name -ResolutionType Single -HorizontalResolution 1920 -VerticalResolution 1080
        }
        # An archived VM keeps its disks NTFS-compressed; Hyper-V only attaches uncompressed disks.
        foreach ($disk in @(Get-VMHardDiskDrive -VMName $name | ForEach-Object Path)) {
            if ((Get-Item -LiteralPath $disk).Attributes -band [IO.FileAttributes]::Compressed) {
                & compact.exe /u /q "$disk" | Out-Null
                if ((Get-Item -LiteralPath $disk).Attributes -band [IO.FileAttributes]::Compressed) { throw "Could not decompress $disk." }
            }
        }
        Start-VM -Name $name
    }
    if ($Action -eq 'Stop') { Stop-VM -Name $name -TurnOff -Force }
    if ($Action -eq 'Nmi') {
        if ((Get-VM -Name $name).State -ne 'Running') { throw 'NMI requires the guest to be running.' }
        Debug-VM -Name $name -InjectNonMaskableInterrupt -Force -Confirm:$false
    }
    if ($Action -eq 'UpdateBoot') {
        if ((Get-VM -Name $name).State -ne 'Off') { throw 'Stop the VM before editing its boot disk.' }
        $bootPath = Join-Path $Machine.VmDirectory 'OpenCore.vhdx'
        try {
            $disk = Mount-VHD -Path $bootPath -PassThru | Get-Disk
            $part = $disk | Get-Partition | Where-Object Type -eq 'System'
            if (-not $part.DriveLetter) { $part | Add-PartitionAccessPath -AssignDriveLetter }
            $part = $disk | Get-Partition | Where-Object Type -eq 'System'
            foreach ($item in 'EFI','Scripts','Tools') {
                $dest = "$($part.DriveLetter):\$item"
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                Get-ChildItem -LiteralPath (Join-Path $root "boot-source\$item") -Force |
                    Copy-Item -Destination $dest -Recurse -Force
            }
        } finally { Dismount-VHD -Path $bootPath -ErrorAction SilentlyContinue }
    }
    $vm = Get-VM -Name $name
    if ($Action -eq 'Inspect') {
        # Explicit, bounded renewal of this already-authorized testing worker.
        # Permanent session controls do not use this worker or this deadline.
        $renewalPath=Join-Path $root 'worker-renew.json'
        if (Test-Path -LiteralPath $renewalPath) {
            $renewal=Get-Content -LiteralPath $renewalPath -Raw | ConvertFrom-Json
            $workerPid=[int](Get-Content -LiteralPath (Join-Path $root 'worker-pid.txt'))
            $workerDeadline=Get-Variable -Name deadline -Scope 1 -ErrorAction SilentlyContinue
            if ($workerPid -ne $PID -or -not $workerDeadline -or $renewal.Minutes -notin @(30,60,120)) {
                throw 'Testing-session renewal did not match the active worker.'
            }
            $limit=(Get-Process -Id $PID).StartTime.AddHours(4)
            $nextDeadline=(Get-Date).AddMinutes([int]$renewal.Minutes)
            if ($nextDeadline -gt $limit) {$nextDeadline=$limit}
            Set-Variable -Name deadline -Scope 1 -Value $nextDeadline
            $result.TestingSessionExpiresAt=$nextDeadline.ToString('o')
            Remove-Item -LiteralPath $renewalPath
        }
    }
    $result.VM = $vm | Select-Object Name,Id,State,CPUUsage,MemoryAssigned,Uptime,Status
    $result.Network = @(Get-VMNetworkAdapter -VMName $name | Select-Object SwitchName,MacAddress,IPAddresses)
    $result.Integration = @(Get-VMIntegrationService -VMName $name | Select-Object Name,Enabled,PrimaryStatusDescription)
    if ($Action -in 'Capture','Key','LoginPassword','Drag') {
        $system = Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_ComputerSystem -Filter "Name='$($vm.Id)'"
        if ($Action -eq 'LoginPassword') {
            $consoleOwner=(& (Join-Path $root 'guest.ps1') -Command "stat -f '%Su' /dev/console") -join ''
            $result.ConsoleOwner=$consoleOwner
            # A locked user session is the other place macOS asks for this password.
            $locked=$false
            if($consoleOwner.Trim() -ne 'root'){
                $lockState=(& (Join-Path $root 'guest.ps1') -Command "ioreg -n Root -d1 -a | plutil -extract IOConsoleUsers.0.CGSSessionScreenIsLocked raw -") -join ''
                $locked=$lockState.Trim() -eq 'true'
                $result.ScreenLocked=$locked
                if(-not $locked){throw 'Neither the login window nor a locked screen was detected; no password was typed.'}
            }
            $keyboard = Get-CimAssociatedInstance -InputObject $system -ResultClassName Msvm_Keyboard
            try {
                if($locked){
                    # The first key only wakes the lock screen's password field.
                    $woke = Invoke-CimMethod -InputObject $keyboard -MethodName TypeKey -Arguments @{KeyCode=[uint32]16}
                    if ($woke.ReturnValue -ne 0) { throw "Wake key failed: $($woke.ReturnValue)" }
                    Start-Sleep -Milliseconds 800
                }
                $credential = Import-Clixml -LiteralPath (Join-Path $root 'guest-credential.clixml')
                $guestPassword = $credential.GetNetworkCredential().Password
                $typed = Invoke-CimMethod -InputObject $keyboard -MethodName TypeText -Arguments @{AsciiText=$guestPassword}
                if ($typed.ReturnValue -ne 0) { throw "Password input failed: $($typed.ReturnValue)" }
                $entered = Invoke-CimMethod -InputObject $keyboard -MethodName TypeKey -Arguments @{KeyCode=[uint32]13}
                if ($entered.ReturnValue -ne 0) { throw "Enter input failed: $($entered.ReturnValue)" }
                $result.LoginSubmitted = $true
            } finally { $guestPassword=$null; $credential=$null }
        } elseif ($Action -eq 'Drag') {
            # Path: "x,y;x,y;..." in guest pixels. Press at the first point, glide
            # through the rest at ~60 Hz, and always release the button.
            # "hover:x,y;..." moves the pointer along the path without pressing a button.
            $hover=$Path.StartsWith('hover:'); if($hover){$Path=$Path.Substring(6)}
            $points=@($Path -split ';' | Where-Object {$_} | ForEach-Object { $xy=$_ -split ','; [pscustomobject]@{X=[int]$xy[0];Y=[int]$xy[1]} })
            if($points.Count -lt 2){throw 'Drag needs at least two points'}
            $mouse = Get-CimAssociatedInstance -InputObject $system -ResultClassName Msvm_SyntheticMouse
            if(-not $mouse){throw 'No synthetic mouse'}
            function MoveTo($x,$y){ $r=Invoke-CimMethod -InputObject $mouse -MethodName SetAbsolutePosition -Arguments @{HorizontalPosition=[int32]$x;VerticalPosition=[int32]$y}; if($r.ReturnValue -ne 0){throw 'Mouse position refused'} }
            MoveTo $points[0].X $points[0].Y
            Start-Sleep -Milliseconds 150
            try {
                if(-not $hover){
                    $down=Invoke-CimMethod -InputObject $mouse -MethodName SetButtonState -Arguments @{ButtonIndex=[uint32]1;IsDown=$true}
                    if($down.ReturnValue -ne 0){throw 'Mouse down refused'}
                }
                Start-Sleep -Milliseconds 120
                for($p=1;$p -lt $points.Count;$p++){
                    $a=$points[$p-1];$b=$points[$p]
                    $steps=[Math]::Max(1,[int]([Math]::Sqrt(($b.X-$a.X)*($b.X-$a.X)+($b.Y-$a.Y)*($b.Y-$a.Y))/8))
                    for($i=1;$i -le $steps;$i++){ MoveTo ($a.X+[Math]::Round(($b.X-$a.X)*$i/$steps)) ($a.Y+[Math]::Round(($b.Y-$a.Y)*$i/$steps)); Start-Sleep -Milliseconds 16 }
                }
                Start-Sleep -Milliseconds 120
            } finally {
                if(-not $hover){
                    $up=Invoke-CimMethod -InputObject $mouse -MethodName SetButtonState -Arguments @{ButtonIndex=[uint32]1;IsDown=$false}
                    $result.ButtonReleased=($up.ReturnValue -eq 0)
                }
            }
            $result.DragPoints=$points.Count
        } elseif ($Action -eq 'Key') {
            $keyboard = Get-CimAssociatedInstance -InputObject $system -ResultClassName Msvm_Keyboard
            $keyResult = Invoke-CimMethod -InputObject $keyboard -MethodName TypeKey -Arguments @{KeyCode=[uint32]$KeyCode}
            $result.KeyResult=$keyResult.ReturnValue
        } else {
            $width=1920; $height=1080; $rowBytes=$width*2
            $service = Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_VirtualSystemManagementService
            $thumb = Invoke-CimMethod -InputObject $service -MethodName GetVirtualSystemThumbnailImage `
                -Arguments @{TargetSystem=$system;WidthPixels=[uint16]$width;HeightPixels=[uint16]$height}
            if ($thumb.ReturnValue -eq 32775) {
                # The host's thumbnail API caps the requested output size.
                $width=1024; $height=768; $rowBytes=$width*2
                $thumb = Invoke-CimMethod -InputObject $service -MethodName GetVirtualSystemThumbnailImage `
                    -Arguments @{TargetSystem=$system;WidthPixels=[uint16]$width;HeightPixels=[uint16]$height}
            }
            if ($thumb.ReturnValue -ne 0) { throw "Thumbnail failed: $($thumb.ReturnValue)" }
            $pixelBytes=[byte[]]$thumb.ImageData
            $expectedBytes=$rowBytes*$height
            [IO.File]::WriteAllBytes((Join-Path $root 'console.rgb565'),$pixelBytes)
            $result.ImageBytes=$pixelBytes.Length
            $result.ImagePrefix=@($pixelBytes[0..7])
            $result.ImageSuffix=@($pixelBytes[($pixelBytes.Length-8)..($pixelBytes.Length-1)])
            # This host prefixes the raster with four metadata bytes.
            # Bounds-check and copy only the declared rows into GDI.
            if ($pixelBytes.Length -notin @($expectedBytes,($expectedBytes+4))) { throw "Unexpected thumbnail length $($pixelBytes.Length); expected $expectedBytes or $($expectedBytes+4)." }
            $pixelOffset=$pixelBytes.Length-$expectedBytes
            $result.ThumbnailMetadataBytes=$pixelOffset
            Add-Type -AssemblyName System.Drawing
            $bitmap = [Drawing.Bitmap]::new($width,$height,[Drawing.Imaging.PixelFormat]::Format16bppRgb565)
            try {
                $rect = [Drawing.Rectangle]::new(0,0,$width,$height)
                $data = $bitmap.LockBits($rect,[Drawing.Imaging.ImageLockMode]::WriteOnly,[Drawing.Imaging.PixelFormat]::Format16bppRgb565)
                try {
                    if ($data.Stride -lt $rowBytes) { throw 'Bitmap stride is smaller than a thumbnail row.' }
                    for ($row=0; $row -lt $height; $row++) {
                        $rowPointer=[IntPtr]::Add($data.Scan0, $row*$data.Stride)
                        [Runtime.InteropServices.Marshal]::Copy($pixelBytes,$pixelOffset+$row*$rowBytes,$rowPointer,$rowBytes)
                    }
                }
                finally { $bitmap.UnlockBits($data) }
                $file=Join-Path $root 'console.png'
                $bitmap.Save($file,[Drawing.Imaging.ImageFormat]::Png)
                $result.Image=$file
            } finally { $bitmap.Dispose() }
        }
    }
    $result.Status='Success'
} catch { $result.Status='Failed'; $result.Error=$_.Exception.Message; $result.Detail=$_.ScriptStackTrace }
finally { $result | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $out -Encoding utf8 }
