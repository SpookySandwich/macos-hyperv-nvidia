# Dot-sourced by the host scripts. Reads machine.json next to this file.
# Create it from machine.example.json; it is git-ignored because it identifies your hardware.
$configPath = Join-Path $PSScriptRoot 'machine.json'
if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Missing $configPath. Copy machine.example.json to machine.json and fill in your VM, GPU and guest values."
}
$Machine = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if (-not $Machine.VmDirectory) { $Machine.VmDirectory = $PSScriptRoot }
if ($Machine.SshKey -like '~*') { $Machine.SshKey = Join-Path $env:USERPROFILE $Machine.SshKey.Substring(2) }
