# OpenCore configuration

Start from [Qonfused/OSX-Hyper-V](https://github.com/Qonfused/OSX-Hyper-V) (OpenCore EFI,
ACPI tables `SSDT-HV-VMBUS`, `SSDT-HV-DEV`, `SSDT-HV-PLUG`, and the Hyper-V kexts) and follow
its guide to install macOS in a Generation 2 VM first. The changes below are what this project
adds. No EFI binaries or `config.plist` are shipped here, because a working `config.plist`
contains your SMBIOS identity (serial number, MLB, ROM, SystemUUID). Generate your own and keep
it private.

## Kexts

| Kext | Where | Notes |
|---|---|---|
| Lilu | OpenCore `Kernel > Add` | from OSX-Hyper-V |
| MacHyperVSupport | OpenCore | upstream build for Big Sur and older (`MaxKernel 20.99.99`) |
| MacHyperVSupportMonterey | OpenCore (`MinKernel 21.0.0`) | **replace** with the 1.0.9 build from `macHyperVSupport.patch` |
| VirtualSMC | OpenCore | from OSX-Hyper-V |
| AMFIPass | OpenCore (`MinKernel 20.0.0`) | lets unsigned graphics components load while keeping normal privacy prompts; used instead of `amfi_get_out_of_my_way` / `amfi=0x80` |
| MacHyperVFramebuffer | OpenCore entry **disabled** | the 1.0.7 build goes into `/Library/Extensions` instead |
| MacHyperVFramebuffer 1.0.7, NVRM, NVRMFB, NVRMAGDC, NVAccel, MacHyperVHeadlessMetal | `/Library/Extensions`, auxiliary kernel collection | installed by `guest/nvidia/install-2.3.1.sh` |

Also: `Kernel > Block` an `Exclude` entry for `com.apple.iokit.IONDRVSupport`.

## NVRAM (`7C436110-AB2A-4BBB-A880-FE41995C9F82`)

```
boot-args          keepsyms=1 nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth -hvgfxtransport -nvrmnoflip
csr-active-config  <430A0000>   (0x0A43)
```

List both keys under `NVRAM > Delete` too, or OpenCore keeps the old values.

- `nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth`: upstream's driver arguments.
- `-hvgfxtransport`: MacHyperVSupport only provides the synthetic aperture as a transport and
  does not publish its own display controller (our patch).
- `-nvrmnoflip`: keep composed frames on the copy path; there is no scan-out to flip to.
- `keepsyms=1`: readable panic logs. The deployed guest also has `debug=0x100` and
  `nvrmsettle=500`; the latter is redundant with 2.3.1.
- Never set `-nvrmsmallbar`: the VM gives the GPU its full 8 GiB BAR above 4 GiB.

`csr-active-config 0x0A43` relaxes SIP enough for unsigned kexts and a writable system
snapshot. Authenticated root must also be disabled (`csrutil authenticated-root disable` from
Recovery) so the Metal bundles can be added to `/System/Library/Extensions`.

## Other settings used

From the setup scripts (applied on top of OSX-Hyper-V's defaults):

- `Kernel > Quirks`: `DisableIoMapper`, `AppleXcpmCfgLock`, `AppleXcpmExtraMsrs`;
  `Kernel > Emulate > DummyPowerManagement`.
- `Misc > Security > SecureBootModel = Disabled`.
- `Booter > Quirks > ResizeAppleGpuBars = -1` and `UEFI > Quirks > ResizeGpuBars = -1`: the GPU
  appears over VMBus after UEFI, so there is nothing to resize pre-boot; the patched PCI bridge
  handles the large BAR.
- `UEFI > Output > Resolution = 1920x1080`.

## Template

A minimal fragment with placeholders, to merge into your own `config.plist`:

```xml
<key>PlatformInfo</key>
<dict>
  <key>Generic</key>
  <dict>
    <key>SystemProductName</key><string>iMac19,1</string>
    <key>SystemSerialNumber</key><string>YOUR-SERIAL</string>
    <key>MLB</key><string>YOUR-MLB</string>
    <key>ROM</key><data>AAAAAAAA</data>
    <key>SystemUUID</key><string>00000000-0000-0000-0000-000000000000</string>
  </dict>
</dict>
<key>NVRAM</key>
<dict>
  <key>Add</key>
  <dict>
    <key>7C436110-AB2A-4BBB-A880-FE41995C9F82</key>
    <dict>
      <key>boot-args</key>
      <string>keepsyms=1 nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth -hvgfxtransport -nvrmnoflip</string>
      <key>csr-active-config</key>
      <data>QwoAAA==</data>
    </dict>
  </dict>
  <key>Delete</key>
  <dict>
    <key>7C436110-AB2A-4BBB-A880-FE41995C9F82</key>
    <array>
      <string>boot-args</string>
      <string>csr-active-config</string>
    </array>
  </dict>
</dict>
```

`SystemProductName` is only an example; use whatever your OSX-Hyper-V setup generated.
