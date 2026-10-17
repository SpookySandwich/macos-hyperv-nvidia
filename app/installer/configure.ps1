param([ValidateSet('Install','Uninstall')][string]$Action='Install',[string]$OwnerSid,[string]$OwnerAccount)
$ErrorActionPreference='Stop'
$appRoot=Split-Path $PSScriptRoot -Parent
$expected=Join-Path $env:ProgramFiles 'macOS'
if([IO.Path]::GetFullPath($appRoot).TrimEnd('\') -ne [IO.Path]::GetFullPath($expected).TrimEnd('\')){throw 'The service must be installed in the protected Program Files location.'}
Import-Module Hyper-V
$machine=Get-Content -LiteralPath (Join-Path $appRoot 'service/machine.json') -Raw | ConvertFrom-Json
$vm=Get-VM -Id ([guid]$machine.VmId)
if($vm.Name -ne $machine.VmName){throw 'The expected macOS VM is unavailable.'}
$data=Join-Path $env:ProgramData 'MacOS'
if($Action -eq 'Uninstall'){
    # Uninstall must not remove recovery facilities from a live GPU session.
    if($vm.State -ne 'Off'){throw 'Shut down macOS before uninstalling. Your VM and disks will be kept.'}
    & (Join-Path $appRoot 'service\host.ps1') -Action Return
    Stop-Service MacOSSession -ErrorAction SilentlyContinue
    & sc.exe delete MacOSSession | Out-Null
    if(Test-Path -LiteralPath (Join-Path $data 'host.json')){
        $cfg=Get-Content -LiteralPath (Join-Path $data 'host.json') -Raw | ConvertFrom-Json
        if($cfg.GrantedConsoleAccess){Revoke-VMConnectAccess -VMName $machine.VmName -UserName $cfg.OwnerAccount -ErrorAction SilentlyContinue}
    }
    return
}
$sid=[Security.Principal.SecurityIdentifier]::new($OwnerSid)
if($sid.Translate([Security.Principal.NTAccount]).Value -ne $OwnerAccount){throw 'The installing user identity does not match.'}
New-Item -ItemType Directory -Path $data -Force | Out-Null
$acl=[Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true,$false)
foreach($principal in @('S-1-5-18','S-1-5-32-544')){
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($principal),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
}
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))
Set-Acl -LiteralPath $data -AclObject $acl
$existing=@(Get-VMConnectAccess -VMName $machine.VmName | Where-Object {$_.UserName -eq $OwnerAccount})
$granted=($existing.Count -eq 0)
if(Test-Path -LiteralPath (Join-Path $data 'host.json')){
    $previous=Get-Content -LiteralPath (Join-Path $data 'host.json') -Raw | ConvertFrom-Json
    if($previous.OwnerSid -eq $OwnerSid -and $previous.GrantedConsoleAccess){$granted=$true}
}
@{OwnerSid=$OwnerSid;OwnerAccount=$OwnerAccount;GrantedConsoleAccess=$granted} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $data 'host.json') -Encoding UTF8
Grant-VMConnectAccess -VMName $machine.VmName -UserName $OwnerAccount
$service=Get-Service MacOSSession -ErrorAction SilentlyContinue
if($service){Stop-Service MacOSSession}
$exe=Join-Path $appRoot 'service\MacOS.Service.exe'
if(-not $service){
    & sc.exe create MacOSSession binPath= ('"'+$exe+'"') start= delayed-auto depend= vmms DisplayName= 'macOS Session'
}else{& sc.exe config MacOSSession binPath= ('"'+$exe+'"') start= delayed-auto depend= vmms}
if($LASTEXITCODE){throw 'Could not register the macOS service.'}
& sc.exe description MacOSSession 'Manages the macOS VM and RTX 4060 ownership. Does not remove a GPU from a running VM.' | Out-Null
& sc.exe failure MacOSSession reset= 86400 actions= restart/5000/restart/15000/restart/30000 | Out-Null
Start-Service MacOSSession
if((Get-Service MacOSSession).Status -ne 'Running'){throw 'The macOS service did not start.'}
