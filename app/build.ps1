param([switch]$SkipPublish)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
# Inputs that are not in the repository (see docs/building.md):
#   src\machine.json                     from src\machine.example.json
#   src\MacOS.App\Interop\*.dll          RDP ActiveX interop, generated with aximp.exe from mstscax.dll
#   src\MacOS.App\Guest\macos-bridge, macos-display, macos-audio.tar.gz   built on macOS by guest\build-guest-helpers.sh
$required=@('src\machine.json','src\MacOS.App\Interop\MSTSCLib.dll','src\MacOS.App\Interop\AxMSTSCLib.dll',
    'src\MacOS.App\Guest\macos-bridge','src\MacOS.App\Guest\macos-display','src\MacOS.App\Guest\macos-audio.tar.gz')
$missing=@($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_)) })
if($missing){throw "Missing build inputs: $($missing -join ', ')"}
$assets=Join-Path $root 'src\MacOS.App\Assets'
New-Item -ItemType Directory -Path $assets -Force | Out-Null
if(-not (Test-Path -LiteralPath (Join-Path $assets 'macOS.ico'))){
    Add-Type -AssemblyName System.Drawing
    $bitmap=[Drawing.Bitmap]::new(256,256)
    $graphics=[Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode='AntiAlias';$graphics.Clear([Drawing.Color]::Transparent)
    $brush=[Drawing.Drawing2D.LinearGradientBrush]::new([Drawing.Rectangle]::new(18,24,220,190),[Drawing.Color]::FromArgb(78,143,230),[Drawing.Color]::FromArgb(99,74,170),45)
    $graphics.FillRectangle($brush,18,24,220,168)
    $pen=[Drawing.Pen]::new([Drawing.Color]::FromArgb(220,230,248),8)
    $graphics.DrawRectangle($pen,18,24,220,168)
    $graphics.FillRectangle([Drawing.Brushes]::LightSlateGray,115,196,26,22)
    $graphics.FillRectangle([Drawing.Brushes]::LightSlateGray,76,219,104,10)
    $font=[Drawing.Font]::new('Segoe UI',42,[Drawing.FontStyle]::Regular)
    $format=[Drawing.StringFormat]::new();$format.Alignment='Center';$format.LineAlignment='Center'
    $graphics.DrawString('mac',$font,[Drawing.Brushes]::White,[Drawing.RectangleF]::new(20,26,216,164),$format)
    $handle=$bitmap.GetHicon();$icon=[Drawing.Icon]::FromHandle($handle)
    $file=[IO.File]::Create((Join-Path $assets 'macOS.ico'));$icon.Save($file);$file.Dispose()
    $icon.Dispose();$font.Dispose();$format.Dispose();$pen.Dispose();$brush.Dispose();$graphics.Dispose();$bitmap.Dispose()
}
& dotnet build (Join-Path $root 'src\MacOS.App') -c Release -p:Platform=x64 --nologo
if($LASTEXITCODE){throw 'App build failed.'}
& dotnet build (Join-Path $root 'src\MacOS.Service') -c Release --nologo
if($LASTEXITCODE){throw 'Service build failed.'}
if($SkipPublish){return}
& dotnet publish (Join-Path $root 'src\MacOS.App') -c Release -r win-x64 --self-contained -p:Platform=x64 -o (Join-Path $root 'publish\app') --nologo
if($LASTEXITCODE){throw 'App publish failed.'}
& dotnet publish (Join-Path $root 'src\MacOS.Service') -c Release -r win-x64 --self-contained -o (Join-Path $root 'publish\service') --nologo
if($LASTEXITCODE){throw 'Service publish failed.'}
$env:MACOS_OWNER_SID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$env:MACOS_OWNER_ACCOUNT=[Security.Principal.WindowsIdentity]::GetCurrent().Name
& 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe' (Join-Path $root 'installer\macOS.iss')
if($LASTEXITCODE){throw 'Installer build failed.'}
