param(
    [ValidateSet('ClipboardToMac','ClipboardFromMac','SendFiles','GetFiles')][string]$Action,
    [string[]]$Files
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'config.ps1')
$address=(Get-NetNeighbor -AddressFamily IPv4 | Where-Object {
    $_.InterfaceAlias -like "*$($Machine.VirtualSwitch)*" -and $_.LinkLayerAddress -eq $Machine.GuestMac
} | Select-Object -First 1).IPAddress
if(-not $address){throw 'Start macOS and wait for guest networking.'}
$key=$Machine.SshKey
if($Action -eq 'ClipboardToMac'){
    $content=Get-Clipboard -Raw
    if($null -eq $content){throw 'Windows clipboard does not contain text.'}
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
    & (Join-Path $PSScriptRoot 'guest.ps1') -Command ("set -e; printf %s "+$encoded+" | base64 -D | pbcopy")
    return 'Text copied to the macOS clipboard.'
}
if($Action -eq 'ClipboardFromMac'){
    $encoded=(& (Join-Path $PSScriptRoot 'guest.ps1') -Command 'set -e; set -o pipefail; pbpaste | base64') -join ''
    $content=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
    if($content.Length){Set-Clipboard -Value $content}else{Set-Clipboard -Value ''}
    return 'Text copied to the Windows clipboard.'
}
if($Action -eq 'SendFiles'){
    if(-not $Files){throw 'Select files to send.'}
    foreach($file in $Files){if(-not (Test-Path -LiteralPath $file -PathType Leaf)){throw "File is unavailable: $file"}}
    & scp -i $key -o BatchMode=yes -o ConnectTimeout=8 @Files "$($Machine.GuestUser)@${address}:/Users/Shared/Exchange/"
    if($LASTEXITCODE){throw 'File transfer failed.'}
    & (Join-Path $PSScriptRoot 'guest.ps1') -Command 'open /Users/Shared/Exchange'
    return 'Files sent to /Users/Shared/Exchange in macOS.'
}
if($Action -eq 'GetFiles'){
    $destination=Join-Path (Split-Path $PSScriptRoot -Parent) 'Exchange'
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    & scp -r -i $key -o BatchMode=yes -o ConnectTimeout=8 "$($Machine.GuestUser)@${address}:/Users/Shared/Exchange/." $destination
    if($LASTEXITCODE){throw 'File transfer failed.'}
    Start-Process explorer.exe -ArgumentList ('"'+$destination+'"') | Out-Null
    return "Files received in $destination."
}
