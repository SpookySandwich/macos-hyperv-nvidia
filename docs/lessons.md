# Lessons

Non-obvious things we ran into. Each one cost real time.

## macOS graphics

- **CoreDisplay detects the GPU vendor from the framebuffer's class name.** It looks for
  `Intel`, `AMD`, `AppleParavirt` or `NVDA` in the IOFramebuffer class name. A name matching
  none of them gives an empty vendor mask, which turns IOPresentment off; WindowServer then
  composites in software and every blur/vibrancy layer shows only its flat fallback tint.
  Renaming the class to `HyperVNVDAGraphicsFramebuffer` fixed it.
- **CoreDisplay's accelerated display path is off by default for NVIDIA.** Setting
  `enableWSAA_onNVIDIA = true` in `/Library/Preferences/com.apple.CoreDisplay.plist` made WindowServer
  issue the real Unaccelerated -> Accelerated transition on the next boot.
- **Do not wrap IOSurfaceDeviceCache control functions.** IOAcceleratorFamily identifies its
  caches by their control function; wrapping it to hook purges panicked WindowServer.
- **WindowServer loads Metal plugins only from `/System/Library/Extensions`.** Installing to
  `/Library/GPUBundles` alone is not enough; the bundles go into a new root snapshot.
- **A barrier inside a Vulkan render pass did not make earlier draws visible to a sampler
  reading the same attachment.** Splitting the pass did. See [black-box-artifact.md](black-box-artifact.md).
- **NVRM publishes its service before GPU initialization finishes.** Wait for
  `nvrm-autogo=up` in the registry before using Metal; earlier queries fail.
- **`kmutil create` returning 0 does not prove a kext is in the collection.** Check with
  `kmutil inspect`. OpenCore-injected kexts (here MacHyperVSupport) are not in the AuxKC at all.
- A screenshot over SSH without Screen Recording permission captures only the wallpaper.

## PCI passthrough into macOS on Hyper-V

- macOS's generic PCI probe caps a BAR at 1 GiB, so an 8 GiB VRAM BAR is split; the
  Hyper-V PCI bridge has to restore the negotiated BARs.
- A prefetchable BAR placed in IOPCIFamily's ordinary range list is silently dropped.
- Advertising L1 PM Substates for an endpoint under a synthetic host bridge makes IOPCIFamily
  dereference a bridge that does not exist.
- After a previous guest instance, the host sometimes never answers the first vPCI version
  query. Unbounded waits hung boot at `NegotiateProtocol`; bounded waits with resends fixed it.
- Hyper-V synthetic video protocol 3.2 caps the framebuffer at 8 MiB even when the host offers
  more; negotiate 3.5 separately from the VMBus version, as Linux does.
- SynIC end-of-message is a per-virtual-processor MSR; write it on the owning CPU.

## Recovery

- **A WindowServer crash can wedge the passed-through GPU.** The reliable way out: shut the VM
  off, return the GPU to Windows (`gpu-ownership.ps1 -Action ReturnGpu`), boot macOS *without*
  the GPU, and fix things over SSH. Keep a copy of every driver file before replacing it; the
  install script keeps a recovery folder and makes a new APFS root snapshot so the previous
  one stays bootable.
- 2.3.1's boot guard switches the driver off after two boots that never reached a display. A VM
  without a monitor needs the console head to clear it (done in the carry). Do not install
  upstream's fallback job (`com.nullmoth.lastgood`); it restores a backup and reboots.

## Hyper-V and Windows

- **DDA requires static memory.** Dynamic Memory cannot be enabled on a VM with an assigned
  device, and the VM's automatic stop action must be TurnOff
  ([Microsoft: Plan for deploying devices using DDA](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/plan/plan-for-deploying-devices-using-discrete-device-assignment)).
- Hyper-V does not attach NTFS-compressed VHDX files; decompress them (`compact /u`) first.
- Close the GPU's Windows users first: assignment refuses while `nvidia-smi` shows an active
  display or memory in use.
- **Windows PowerShell 5.1 `ConvertTo-Json` turns an empty pipeline result into `{}`.**
  `$x = @(... | Select-Object -First 1)` that matches nothing, put into a hashtable, serializes
  as `{}` (AutomationNull), not `null`. Assign `$null` explicitly
  (`Address=$(if($ip){[string]$ip[0]}else{$null})`).
- Windows PowerShell 5.1 strips the quotes around `bash -c '...'` that PowerShell 7 keeps.
  Sending the script to `bash -s` on stdin avoids nested quoting (`host/guest.ps1`).
- `GetVirtualSystemThumbnailImage` caps the requested size (1024x768 here) and prefixes the
  RGB565 raster with 4 metadata bytes on this host.
- On battery, this laptop held the CPU at about 15 W while the VM owned the RTX 4060; with the
  VM off it drew over 60 W.
