param([ValidateRange(1,180)][int]$TimeoutSeconds=80,[string]$OutputPath='')
$ErrorActionPreference='Stop'
$limit=(Get-Date).AddSeconds($TimeoutSeconds)
$lastStage='SSH unavailable'
$attempts=[Collections.Generic.List[object]]::new()
$started=Get-Date
if($OutputPath){
    @{Ready=$false;CheckStartedAt=$started.ToString('o');Attempts=@()} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
}
$probe=@'
import json,plistlib,subprocess
def registry(name):
    data=subprocess.check_output(['ioreg','-a','-r','-c',name],timeout=5)
    return plistlib.loads(data) if data.strip() else []
rows=registry('HyperVVMBusDevice')
stage='No virtual PCI bridge'
for row in rows:
    if row.get('HVType')=='44c4f61d-4444-4400-9d52-802e27ede19f':
        stage=row.get('HyperVPCIInitStage','Unknown')
accelerators=registry('NVAccel')
managers=registry('NVRM')
framebuffers=registry('HyperVGraphicsFramebuffer')
framebuffer_ready=any(row.get('HyperVConsoleScanoutReady') is True and
                      row.get('HyperVConsoleRegistrationStatus')==0 for row in framebuffers)
rmstage=next((row.get('nvrm-autogo','Unknown') for row in managers),'No resource manager')
report={'BridgeStage':stage,'RmStage':rmstage,'RmInitialized':rmstage=='up','NvAccelLoaded':bool(accelerators),
        'FramebufferReady':framebuffer_ready,'NativeMetalPassed':False,'Ready':False}
# NVRM publishes its service before go(2) finishes. Its escape handler refuses
# every hardware query until then; older NVK error handling can assert on the
# resulting zero architecture. Use the explicit completion signal, not a delay.
if stage=='Ready' and accelerators and report['RmInitialized'] and framebuffer_ready:
    try:
        import os
        p=subprocess.run([os.path.expanduser('~/hyperv-build/metal-smoke-latest')],capture_output=True,text=True,timeout=20)
        report['NativeMetalPassed']=p.returncode==0 and 'NVIDIA' in p.stdout and 'METAL_COMPUTE_AND_RENDER_PASS' in p.stdout
        report['ProbeExitCode']=p.returncode
        report['ProbeOutput']=p.stdout[-4096:]
        report['ProbeErrors']=p.stderr[-4096:]
    except subprocess.TimeoutExpired:
        report['ProbeTimeout']=True
    report['Ready']=report['NativeMetalPassed']
print(json.dumps(report))
'@
$encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($probe))
$command="printf %s $encoded | base64 -D | /usr/bin/python3"
while((Get-Date)-lt $limit){
    try{
        $text=(& (Join-Path $PSScriptRoot 'guest.ps1') -Command $command) -join "`n"
        $state=$text | ConvertFrom-Json
        $lastStage="$($state.BridgeStage); resource manager: $($state.RmStage)"
        $attempts.Add([pscustomobject]@{At=(Get-Date).ToString('o');State=($text | ConvertFrom-Json)})
        $state | Add-Member -NotePropertyName Attempts -NotePropertyValue @($attempts.ToArray())
        $state | Add-Member -NotePropertyName ElapsedSeconds -NotePropertyValue ([math]::Round(((Get-Date)-$started).TotalSeconds,2))
        if($OutputPath){$state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8}
        if($state.Ready){return $state}
        # The registry can publish NVAccel before its user-space queues are
        # usable. Retry within the startup deadline, retaining every failure.
    }catch{
        $attempts.Add([pscustomobject]@{At=(Get-Date).ToString('o');Error=$_.Exception.Message})
        if($OutputPath){
            @{Ready=$false;LastStage=$lastStage;CheckStartedAt=$started.ToString('o');Attempts=@($attempts.ToArray())} |
                ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
        }
    }
    Start-Sleep -Seconds 2
}
if($OutputPath){
    @{Ready=$false;TimedOut=$true;LastStage=$lastStage;CheckStartedAt=$started.ToString('o');Attempts=@($attempts.ToArray())} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
}
throw "macOS started, but its GPU did not become ready (virtual PCI: $lastStage). Use Shut down and return GPU to recover."
