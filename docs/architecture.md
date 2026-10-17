# Architecture

## Host and VM

- Host: Windows 11 with Hyper-V, a laptop with an Intel Core Ultra 9 185H (Intel Arc
  integrated graphics drives the built-in panel) and an RTX 4060 Laptop GPU (`10de:28a0`).
  The laptop has no display MUX.
- VM: Generation 2, Secure Boot off, 8 vCPUs, 6 GiB **static** memory, NAT through the
  "Default Switch" with a static MAC, two SCSI disks (a small FAT32 OpenCore disk and the
  macOS disk). Settings needed for Discrete Device Assignment (DDA):
  `AutomaticStopAction TurnOff`, `GuestControlledCacheTypes $true`,
  `LowMemoryMappedIoSpace 3GB`, `HighMemoryMappedIoSpace 32GB`, Dynamic Memory off.
- Guest: macOS 15.8.1 (24H32), OpenCore based on
  [Qonfused/OSX-Hyper-V](https://github.com/Qonfused/OSX-Hyper-V). See [opencore.md](opencore.md).

## GPU ownership and handoff

The GPU belongs to Windows by default. A session moves it to the VM and back without
restarting Windows. The logic is in `host/gpu-ownership.ps1` and `host/session-control.ps1`
(scripted use) and in `app/src/MacOS.Service/host.ps1` (the Windows app's service). Both
take a named mutex so only one ownership operation runs at a time.

Assign (VM must be off):

1. Check that the expected GPU is healthy at the expected PCI location, the Intel display is
   active, `nvidia-smi` reports no active display and 0 MiB in use, and the host reports
   `IovSupport`.
2. `Disable-PnpDevice` on the GPU.
3. `Dismount-VMHostAssignableDevice -Force -LocationPath <path>`.
4. `Add-VMAssignableDevice -VMName <vm> -LocationPath <path>`.
5. Start the VM and wait until the guest reports the virtual PCI bridge `Ready`,
   `nvrm-autogo=up`, the framebuffer scan-out ready, and a small Metal compute/render check
   (`guest/tools/metal-smoke.m`) passes.

If any step fails while the VM is still off, the GPU is returned.

Return (VM must be fully off; a running guest is shut down gracefully, never forced):

1. `Remove-VMAssignableDevice`.
2. `Mount-VMHostAssignableDevice`.
3. `Enable-PnpDevice` if Windows reports problem code 22 (disabled).
4. Wait for problem code 0, then check `nvidia-smi`.

The Windows boot entry needs `hypervisoriommupolicy Enable` (`bcdedit`, done once by
`session-control.ps1 -Action PersistBoot`).

## Display path

The RTX 4060 renders and composites the desktop, but it has no monitor. The picture reaches
Windows through Hyper-V's synthetic video device:

```
 macOS apps ──Metal──> NVMTLDriver (Metal plugin, NVK/Vulkan)
                              │
 WindowServer composites on the RTX 4060 (Metal compositor, IOPresentment)
                              │  composed frame in GPU VRAM
                              v
 NVAccel (Hyper-V carry): copy engine VRAM -> 32 MiB system-memory pool
                              │  "completed frame" handed over by commit
                              v
 MacHyperVFramebuffer 1.0.7 (HyperVNVDAGraphicsFramebuffer, bound to the GPU's PCI device)
                              │
 MacHyperVSupport 1.0.9: compare with cached reference, write changed rows
                         into the synthetic video aperture, notify dirty rows over VMBus
                              │
 Hyper-V synthetic video (host side)
                              │  RDP-based console protocol
                              v
 vmconnect.exe, or the Windows app (RDP ActiveX control)
```

Each frame is therefore copied out of GPU memory, compared and copied again in the guest, then
encoded and sent through the console protocol on the host. That is why the desktop feels
laggy even though rendering is GPU-accelerated. See [display-options.md](display-options.md).

## Guest driver stack

| Component | Version | Source | Loaded from |
|---|---|---|---|
| Lilu | 1.7.2 | acidanthera | OpenCore |
| VirtualSMC | 1.3.8 | acidanthera (part of OSX-Hyper-V) | OpenCore |
| MacHyperVSupport (Monterey build) | 1.0.9 | acidanthera `cafcd34` + `macHyperVSupport.patch` | OpenCore |
| AMFIPass | 1.4.1 | dhinakg | OpenCore |
| MacHyperVFramebuffer | 1.0.7 | acidanthera `cafcd34` + `macHyperVSupport.patch` | `/Library/Extensions` (AuxKC) |
| NVRM, NVRMFB | 2.3.1 release | nullmoth, unchanged | `/Library/Extensions` (AuxKC) |
| NVAccel, NVRMAGDC | 2.3.1d1 | nullmoth `v2.3.1` + `hyperv-kexts.patch` | `/Library/Extensions` (AuxKC) |
| MacHyperVHeadlessMetal | 0.1.1 | ours, `guest/headless-metal` | `/Library/Extensions` (AuxKC) |
| NVMTLDriver.bundle | 2.3.1 release with patched `NVMTLDriver` binary | nullmoth `v2.3.1` + `metal-plugin-fixes.patch` | `/System/Library/Extensions` (new root snapshot) |
| NVIDIAShared.bundle, `nvmtl/` | 2.3.1 release | nullmoth, unchanged | `/System/Library/Extensions` |
| GSP firmware | 610.57.04 | NVIDIA, via the 2.3.1 release | `/Users/Shared/nvfw` |

WindowServer only loads Metal plugins from `/System/Library/Extensions`, so the bundles are
installed into a new APFS root snapshot (`guest/nvidia/install-2.3.1.sh`), with symlinks
from `/Library/GPUBundles`.

Guest settings outside the drivers:

- `enableWSAA_onNVIDIA = true` in `/Library/Preferences/com.apple.CoreDisplay.plist`. CoreDisplay's
  default for NVIDIA is false; without it WindowServer never moves to the accelerated display path.
- SIP partially disabled (`csr-active-config` `0x0A43`) and authenticated root disabled, so
  the system volume can take the Metal bundles.

## Windows app

`app/` is a WinUI 3 viewer and a Windows service:

- `MacOS.Service` (runs as LocalSystem) owns the VM and GPU lifecycle through `host.ps1` and
  listens on a named pipe restricted to the installing user. It shuts macOS down gracefully on
  low battery and never removes the GPU from a running VM.
- `MacOS.App` hosts the VM console with the RDP ActiveX control, waits until the guest
  desktop is really ready (`app/guest/readiness.py` over SSH), can type the guest password at
  the login screen from a DPAPI-protected credential file, and bridges clipboard, display mode
  and audio through small guest helpers (`app/guest/*.m`, `audio.mm`).
- `installer/macOS.iss` builds an Inno Setup installer that registers the service.
