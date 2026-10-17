# Building and installing

Everything that runs inside macOS is built **in the guest** with the Xcode Command Line Tools
(`xcode-select --install`). The guest scripts use `/usr/bin/python3` from those tools. The
Windows parts need Windows PowerShell 5.1, the .NET 10 SDK and Inno Setup 6.

Work in a scratch directory in the guest, for example `~/hyperv-build`. Before replacing any
driver, keep copies of the old ones; see [lessons.md](lessons.md#recovery).

## 1. Dependencies (guest)

```bash
cd ~/hyperv-build
git clone https://github.com/acidanthera/MacKernelSDK
git clone https://github.com/KhronosGroup/Vulkan-Headers && git -C Vulkan-Headers checkout v1.4.365
git clone https://github.com/NVIDIA/open-gpu-kernel-modules ogkm610 && git -C ogkm610 checkout 610.57.04
```

Download the nvidia-macos-driver **2.3.1** release package from
[the releases page](https://github.com/nullmoth/nvidia-macos-driver/releases/tag/v2.3.1) and
unpack its `pkgroot/` to `~/hyperv-build/rebase-2.3.1/release/pkgroot`. It provides NVRM,
NVRMFB, the Metal bundles and the GSP firmware; follow upstream's instructions for the firmware
location. Do **not** run upstream's `install.sh` (it replaces the `/Library/GPUBundles` symlinks
and installs a fallback job that reboots).

## 2. NVIDIA kexts and Metal plugin

```bash
git clone https://github.com/nullmoth/nvidia-macos-driver && cd nvidia-macos-driver
git checkout v2.3.1
git apply /path/to/repo/patches/nvidia-macos-driver/hyperv-kexts.patch
git apply /path/to/repo/patches/nvidia-macos-driver/metal-plugin-fixes.patch

# NVAccel.kext + NVRMAGDC.kext (ad-hoc signed)
MACKERNELSDK=~/hyperv-build/MacKernelSDK OGKM=~/hyperv-build/ogkm610 \
  bash build/hyperv_build.sh "$PWD" ~/hyperv-build/rebase-2.3.1-out

# NVMTLDriver
VULKAN_HEADERS=~/hyperv-build/Vulkan-Headers \
  bash /path/to/repo/guest/nvidia/build-metal-plugin.sh "$PWD" ~/hyperv-build/plugin-out
cp ~/hyperv-build/plugin-out/NVMTLDriver \
   ~/hyperv-build/rebase-2.3.1/release/pkgroot/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver
```

`hyperv_build.sh` builds only the macOS 15 NVAccel and NVRMAGDC; NVRM and NVRMFB come from the
release.

## 3. MacHyperVSupport and MacHyperVFramebuffer

```bash
git clone https://github.com/acidanthera/MacHyperVSupport && cd MacHyperVSupport
git checkout cafcd34
git apply /path/to/repo/patches/macHyperVSupport.patch
ln -s ~/hyperv-build/MacKernelSDK MacKernelSDK
# Lilu.kext: a DEBUG build of Lilu in ./Lilu.kext (upstream's build expects the same)
HYPERV_SOURCE_ROOT=$PWD /usr/bin/python3 /path/to/repo/guest/machypervsupport/build-support.py
HYPERV_SOURCE_ROOT=$PWD /usr/bin/python3 /path/to/repo/guest/machypervsupport/build-framebuffer.py
codesign --force --sign - build-local/MacHyperVSupportMonterey.kext build-framebuffer/MacHyperVFramebuffer.kext
```

- Put `MacHyperVSupportMonterey.kext` into the OpenCore EFI (`EFI/OC/Kexts`), replacing the
  upstream one.
- Put `MacHyperVFramebuffer.kext` into `/Library/Extensions` (`root:wheel`, not group/other
  writable). Its `IOPCIMatch` is `0x28A010DE` (RTX 4060 Laptop); edit
  `MacHyperVFramebuffer/Info-HyperVNVDA.plist` for another GPU.

## 4. MacHyperVHeadlessMetal

```bash
MACKERNELSDK=~/hyperv-build/MacKernelSDK /usr/bin/python3 /path/to/repo/guest/headless-metal/build.py
codesign --force --sign - /path/to/repo/guest/headless-metal/build/MacHyperVHeadlessMetal.kext
sudo ditto /path/to/repo/guest/headless-metal/build/MacHyperVHeadlessMetal.kext /Library/Extensions/MacHyperVHeadlessMetal.kext
```

The kext also matches only `10de:28a0`; edit `HeadlessMetal.cpp` for another GPU.

## 5. Install

```bash
sudo bash /path/to/repo/guest/nvidia/install-2.3.1.sh      # EFI_DEV=/dev/diskXsY if the EFI is not disk0s2
sudo defaults write /Library/Preferences/com.apple.CoreDisplay enableWSAA_onNVIDIA -bool true
sudo reboot
```

The install script backs up everything it replaces into `/Users/Shared/hyperv-recovery/…`,
rebuilds the auxiliary kernel collection (framebuffer, NVRM, NVRMFB, NVRMAGDC, NVAccel,
headless Metal), installs the Metal bundles into a new root snapshot, and adds `-nvrmnoflip`
to the OpenCore boot-args. `rollback-2.3.1.sh <recovery-folder>` undoes it.

After the reboot, check `kextstat | grep -E 'nullmoth|goldfish64'` for NVAccel 2.3.1d1,
MacHyperVSupport 1.0.9 and MacHyperVFramebuffer 1.0.7, and judge the desktop visually.

Also build `guest/tools/metal-smoke.m` to `~/hyperv-build/metal-smoke-latest`
(`xcrun clang -fobjc-arc -framework Foundation -framework Metal -framework IOKit metal-smoke.m -o ~/hyperv-build/metal-smoke-latest`);
`host/wait-guest-graphics.ps1` runs it to decide that a session is ready.

## 6. Host scripts (Windows)

```powershell
cd host
Copy-Item machine.example.json machine.json   # then fill in your VM ID, GPU instance/location path, MAC, guest user
# SSH key for the guest: ~/.ssh/id_macos_hyperv (public key in the guest's ~/.ssh/authorized_keys)
# Optional, for the scripted login: Get-Credential <guest-user> | Export-Clixml guest-credential.clixml
```

Run elevated: `manage-hyperv.ps1 -Action StartSession` (assign the GPU, start, wait for Metal)
and `-Action ShutdownAndReturn`. `run-testing-worker.ps1` starts one elevated worker that
serves requests from a non-elevated shell via `request-worker.ps1 -Action <name>`.

## 7. Windows app

1. `Copy-Item app\src\machine.example.json app\src\machine.json` and fill it in.
2. Generate the RDP ActiveX interop assemblies into `app\src\MacOS.App\Interop\`:
   `aximp.exe C:\Windows\System32\mstscax.dll` (Windows SDK, .NET Framework tools) produces
   `MSTSCLib.dll` and `AxMSTSCLib.dll`.
3. In the guest, run `app/guest/build-guest-helpers.sh` and copy `macos-bridge`,
   `macos-display` and `macos-audio.tar.gz` into `app\src\MacOS.App\Guest\`.
4. Run `app\build.ps1` (builds, publishes and creates `dist\macOS-Setup.exe` with Inno Setup).
5. The saved guest password the app types at the login screen is read from
   `%LOCALAPPDATA%\MacOS\guest-credential.clixml`
   (`Get-Credential <guest-user> | Export-Clixml $env:LOCALAPPDATA\MacOS\guest-credential.clixml`;
   DPAPI-protected for your Windows user).

Audio forwarding needs BlackHole 2ch in the guest and microphone consent for the
"macOS Audio" helper.
