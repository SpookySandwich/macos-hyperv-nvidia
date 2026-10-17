param([ValidateRange(1,300)][int]$TimeoutSeconds=100)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'config.ps1')
$deadline=(Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    $addresses=@(Get-NetNeighbor -AddressFamily IPv4 | Where-Object {
        $_.InterfaceAlias -like "*$($Machine.VirtualSwitch)*" -and $_.LinkLayerAddress -eq $Machine.GuestMac
    } | Select-Object -ExpandProperty IPAddress -Unique)
    foreach ($address in $addresses) {
        $client=[Net.Sockets.TcpClient]::new()
        try {
            $connection=$client.ConnectAsync($address,22)
            if ($connection.Wait(700) -and $client.Connected) {
                Write-Output "Guest SSH port ready: $address"
                return
            }
        } catch { } finally { $client.Dispose() }
    }
    Start-Sleep -Seconds 2
}
throw "Guest SSH did not become available within $TimeoutSeconds seconds."
