# macOS on Hyper-V with an NVIDIA RTX 4060 (Metal)

![macOS Sequoia with an RTX 4060 running in a Hyper-V VM on Windows 11](docs/images/macos-on-windows.png)

macOS 15.8.1 (Sequoia) running in a Hyper-V virtual machine on Windows 11, with the laptop's
RTX 4060 passed through by Discrete Device Assignment (DDA) and accelerated by
[nullmoth/nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver) v2.3.1 plus
the Hyper-V patches in this repository. The GPU is handed back to Windows when macOS shuts
down, without restarting Windows.

This is a personal, noncommercial project. It documents what we built and shares the
patches and scripts; it is not a product or an installer you can run blind.

**Almost all of the hard work here is other people's.** The NVIDIA Metal driver is NullMoth's,
the Hyper-V support for macOS is Goldfish64's and acidanthera's, the Hyper-V OpenCore setup is
Qonfused's, and the boot stack is acidanthera's. What this repository adds is incremental: the
glue that lets the upstream driver drive a GPU passed through to a Hyper-V VM with no monitor,
a few fixes found along the way, and notes. See [Credits](#credits).

## Status

What works:

- Metal 3 on the RTX 4060 inside the VM: WindowServer and apps render on the GPU (System
  Information reports "Metal Support: Metal 3").
- GPU handoff: assign the RTX 4060 to the VM, start macOS, shut down, and return the GPU to
  the Windows NVIDIA driver, all without a Windows restart.
- Desktop compositing on the GPU, including blur and vibrancy (Dock, menus, sidebars).
- The "black box in inactive windows" artifact is fixed
  ([docs/black-box-artifact.md](docs/black-box-artifact.md)).

Limits:

- **The display path is laggy.** The RTX 4060 has no monitor here, so every frame is copied
  out of GPU memory into Hyper-V's synthetic framebuffer and then shown through Hyper-V's
  RDP-based console viewer. Rendering is fast; getting pixels to the screen is not.
- **No direct monitor** unless one is connected to the port wired to the RTX 4060 (likely HDMI; untested in the
  VM). The laptop has no MUX: the internal panel is always on the Intel GPU, and the RTX 4060
  reports a single external connector.
- **Streaming** with Sunshine and Moonlight was evaluated: smooth, but it looks like video, and
  NVENC hardware encoding is not usable on pre-Blackwell GPUs with this driver.
- **Static memory only.** DDA does not work with Dynamic Memory
  ([Microsoft: plan for DDA](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/plan/plan-for-deploying-devices-using-discrete-device-assignment)).
- **Unsupported host.** Microsoft documents DDA for Windows Server. On Windows 11 (Pro, or Home
  with Hyper-V enabled as here) it works but is not supported.
- Tested on one machine and one GPU (RTX 4060 Laptop, `10de:28a0`). Device IDs are matched
  explicitly in several places.

See [docs/display-options.md](docs/display-options.md) for the display alternatives.

## Requirements

- Windows 11 with Hyper-V, IOMMU (VT-d) enabled, and a GPU that DDA can dismount. Free GPU
  memory first: assignment is refused while Windows uses the GPU.
- An NVIDIA GPU supported by nvidia-macos-driver (Turing or newer), and an integrated GPU to
  keep the Windows desktop running while the dGPU is in the VM.
- A macOS 15 VM built with [Qonfused/OSX-Hyper-V](https://github.com/Qonfused/OSX-Hyper-V)
  (OpenCore, Generation 2).
- In the guest: Xcode Command Line Tools to build the patched drivers.
- On Windows (for the app): .NET 10 SDK, Windows SDK (`aximp.exe`), Inno Setup 6.

## Setup outline

1. Install macOS in a Generation 2 Hyper-V VM with OSX-Hyper-V. Give the VM static memory,
   `AutomaticStopAction TurnOff`, and enough MMIO space
   (`Set-VM -LowMemoryMappedIoSpace 3GB -HighMemoryMappedIoSpace 32GB -GuestControlledCacheTypes $true`).
2. Enable the hypervisor IOMMU policy for your Windows boot entry
   (`bcdedit /set {default} hypervisoriommupolicy Enable`, then reboot once).
3. In the guest, build and install the patched drivers: [docs/building.md](docs/building.md).
4. Apply the OpenCore changes: [docs/opencore.md](docs/opencore.md).
5. On Windows, fill in `host/machine.json` and use `host/manage-hyperv.ps1 -Action StartSession`
   / `-Action ShutdownAndReturn` (elevated), or build the Windows app in `app/`.

This is a record of one working setup, not a turnkey installer. The patches reproduce the
drivers that ran in the screenshot; the build and helper scripts were cleaned up and
parameterized for publication and have not been re-run from this repository since, so expect
to adapt them.

How it fits together: [docs/architecture.md](docs/architecture.md). What each patch changes and
why: [docs/driver-changes.md](docs/driver-changes.md). Things we learned the hard way:
[docs/lessons.md](docs/lessons.md).

## Repository layout

| Path | Contents |
|---|---|
| `patches/nvidia-macos-driver/` | Patches against nvidia-macos-driver `v2.3.1`: NVAccel/NVRMAGDC Hyper-V carry, Metal plugin fixes |
| `patches/macHyperVSupport.patch` | Patch against acidanthera/MacHyperVSupport `cafcd34`: Support 1.0.9 and Framebuffer 1.0.7 |
| `guest/` | Build and install scripts run inside macOS; MacHyperVHeadlessMetal source |
| `host/` | PowerShell scripts for the VM and GPU lifecycle on Windows |
| `app/` | Windows viewer app and service (WinUI 3, .NET), installer, guest helper sources |
| `docs/` | Documentation |

## Credits

This project stands on the following work. Thank you to everyone involved.

**The NVIDIA driver**

- [NullMoth Systems / nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver):
  the NVIDIA Metal driver for macOS (kernel extensions, Metal plugin, framebuffer, accelerator).
  Everything GPU-related here is a small set of patches on top of it, and several of our fixes
  are ports or extensions of theirs.
- The upstream driver's own foundations:
  [NVIDIA open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules) (r610),
  [Mesa](https://gitlab.freedesktop.org/mesa/mesa) NVK and the NAK compiler, and
  [metal2vulkan](https://github.com/steelbrain/metal2vulkan) by Anees Iqbal, on which the
  shader translator is based.
- Upstream contributors whose fixes this setup relies on, among them @imbrahiam (#200, keeping
  a surface's VRAM across page-off), @imyago9 (#147, reporting work as scheduled only after
  IOSurface writes finish) and the reporters of #65 and #206 (the NVENC encoder status on
  pre-Blackwell GPUs), plus everyone who filed logs and tested releases.

**macOS on Hyper-V**

- [acidanthera/MacHyperVSupport](https://github.com/acidanthera/MacHyperVSupport) by
  Goldfish64: Hyper-V VMBus, storage, network, input, PCI passthrough and the synthetic
  framebuffer for macOS. Our Hyper-V display changes are a patch on top of it.
- [Qonfused/OSX-Hyper-V](https://github.com/Qonfused/OSX-Hyper-V): the OpenCore configuration
  and scripts for running macOS on Hyper-V that this VM was built from.
- [OpenCore](https://github.com/acidanthera/OpenCorePkg), [Lilu](https://github.com/acidanthera/Lilu),
  [VirtualSMC](https://github.com/acidanthera/VirtualSMC) and
  [MacKernelSDK](https://github.com/acidanthera/MacKernelSDK) by acidanthera and contributors.
- [AMFIPass](https://github.com/dhinakg/AMFIPass) by dhinakg.

**References we learned from**

- Apple's open source releases ([apple-oss-distributions](https://github.com/apple-oss-distributions)),
  in particular IOGraphics and IOPCIFamily, for how macOS framebuffers and PCI devices behave.
- The Linux Hyper-V PCI driver (`drivers/pci/controller/pci-hyperv.c` in the
  [Linux kernel](https://github.com/torvalds/linux)), as the reference for the Hyper-V
  virtual PCI protocol.
- Microsoft's [Discrete Device Assignment documentation](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/plan/plan-for-deploying-devices-using-discrete-device-assignment).
- [Sunshine](https://github.com/LizardByte/Sunshine) and
  [Moonlight](https://github.com/moonlight-stream/moonlight-qt), which we used to evaluate
  streaming as a display path.

**Windows app**

- [NAudio](https://github.com/naudio/NAudio); the virtual-desktop interop was checked against
  [MScholtes/VirtualDesktop](https://github.com/MScholtes/VirtualDesktop).

If we missed someone whose work is in here, please open an issue and we will add them.

## License

- Our own code (host scripts, Windows app, guest scripts, MacHyperVHeadlessMetal) and the
  documentation: [MIT](LICENSE).
- `patches/nvidia-macos-driver/*` modify code licensed under the
  [PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0)
  and are distributed under that license, noncommercial use only.
- `patches/macHyperVSupport.patch` modifies BSD-3-Clause code and is distributed under the
  BSD-3-Clause license.

See [NOTICE](NOTICE) for details. macOS is a trademark of Apple Inc.; NVIDIA and GeForce are
trademarks of NVIDIA Corporation. This project is not affiliated with either. Running macOS
in a VM on non-Apple hardware may be restricted by Apple's license terms.
