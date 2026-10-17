param([Parameter(Mandatory)][string]$Command,[switch]$Sudo,[string]$Address='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'config.ps1')
if (-not $Address) {
    $Address=(Get-NetNeighbor -AddressFamily IPv4 | Where-Object {
        $_.InterfaceAlias -like "*$($Machine.VirtualSwitch)*" -and $_.LinkLayerAddress -eq $Machine.GuestMac
    } | Select-Object -First 1).IPAddress
}
if (-not $Address) { throw 'Guest IP is unavailable.' }
$key=$Machine.SshKey
# Send the script over stdin, without nested native-command quoting. Windows
# PowerShell 5.1 strips the quotes around `bash -c` that PowerShell 7 preserves.
$remote=if($Sudo){"sudo -k -S -p '' /bin/bash -s"}else{'/bin/bash -s'}
$start=[Diagnostics.ProcessStartInfo]::new()
$start.FileName=(Get-Command ssh.exe).Source
$start.Arguments='-i "'+$key+'" -o BatchMode=yes -o ConnectTimeout=8 -T '+$Machine.GuestUser+'@'+$Address+' '+$remote
$start.UseShellExecute=$false;$start.CreateNoWindow=$true
$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
$start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
$start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
$process=$null;$guestPassword=$null;$credential=$null
try{
    $process=[Diagnostics.Process]::Start($start)
    $process.StandardInput.NewLine="`n"
    $errors=$process.StandardError.ReadToEndAsync()
    if($Sudo){
        $credential=Import-Clixml -LiteralPath (Join-Path $PSScriptRoot 'guest-credential.clixml')
        $guestPassword=$credential.GetNetworkCredential().Password
        if(-not $guestPassword){throw 'VM credential is unavailable.'}
        # -k forces sudo to consume this first line even if a ticket is cached.
        $process.StandardInput.WriteLine($guestPassword)
        $guestPassword=$null;$credential=$null
    }
    $process.StandardInput.WriteLine($Command.Replace("`r`n","`n"))
    $process.StandardInput.Close()
    while(($line=$process.StandardOutput.ReadLine()) -ne $null){Write-Output $line}
    $process.WaitForExit()
    $errorText=$errors.GetAwaiter().GetResult()
    if($errorText){[Console]::Error.WriteLine($errorText.TrimEnd())}
    if($process.ExitCode){throw "Guest command failed: $($process.ExitCode)"}
}finally{
    $guestPassword=$null;$credential=$null
    if($process){if(-not $process.HasExited){$process.Kill()};$process.Dispose()}
}
