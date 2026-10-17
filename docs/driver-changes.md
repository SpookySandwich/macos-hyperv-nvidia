# Driver changes

Everything here ships as patches against pinned upstream commits. Nothing in this
repository is a copy of an upstream tree.

| Patch | Upstream | Base | Builds |
|---|---|---|---|
| `patches/nvidia-macos-driver/hyperv-kexts.patch` | [nullmoth/nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver) | tag `v2.3.1` (`418051b`) | `NVAccel.kext`, `NVRMAGDC.kext` (2.3.1d1, shown as 2.3.1-hv1) |
| `patches/nvidia-macos-driver/metal-plugin-fixes.patch` | same | tag `v2.3.1` | `NVMTLDriver` (Metal plugin binary) |
| `patches/macHyperVSupport.patch` | [acidanthera/MacHyperVSupport](https://github.com/acidanthera/MacHyperVSupport) | `cafcd34` | `MacHyperVSupportMonterey.kext` 1.0.9, `MacHyperVFramebuffer.kext` 1.0.7 |
| `guest/headless-metal/` | ours | - | `MacHyperVHeadlessMetal.kext` 0.1.1 |

Upstream NVRM.kext, NVRMFB.kext, NVIDIAShared.bundle, the shader translator and the GSP
firmware are used unchanged from the 2.3.1 release. See [building.md](building.md) for how
to apply and build.

## Provenance

Each patch was checked against the sources that produced the binaries loaded in the
running guest:

- `hyperv-kexts.patch` applied to `git archive v2.3.1 kexts build` reproduces the build tree
  byte for byte. The NVAccel and NVRMAGDC built from that tree are the loaded 2.3.1d1 kexts
  (same SHA-256 as the build output).
- `metal-plugin-fixes.patch` applied to `v2.3.1 plugin` reproduces the plugin source that
  built the installed `NVMTLDriver` (identical except line endings).
- `macHyperVSupport.patch` reproduces the guest build trees of the loaded kexts: the Support
  tree whose build output has the loaded binary's SHA-256 and UUID, and the framebuffer tree
  whose signed output has the loaded framebuffer's SHA-256. Line endings are normalized to
  the upstream repository's LF. Three diagnostic framebuffer files that were present in that
  tree but not compiled (`PFBackingWitness.*`, `PFBackingUserMapWitness.cpp`) are left out.
  The framebuffer was compiled against an older copy of `publication/HyperVCompletedFrameAbi.hpp`
  that lacks one enum value (`HP_REPLY_EXACT_ROWS`) and one comment; the patch ships the newer
  copy that Support used. A rebuild from the patch was not run, so binary identity is not
  claimed. A local Windows clone of MacHyperVSupport with an older set of changes was not used.

## NVIDIA kernel side (`hyperv-kexts.patch`)

Upstream drives a monitor through its own framebuffer (NVRMFB). In this VM the RTX 4060 has
no monitor, and the only display macOS has is Hyper-V's synthetic one. The carry lets
WindowServer composite on the NVIDIA GPU and copies finished frames to that synthetic
display. Every carried hunk is marked `HYPERV-CARRY` in the code.

| Change | Where | Why |
|---|---|---|
| Console head | `nvrm-accel.cpp`: `registerFramebufferLocked`, `onCountGrewLocked`, `configureConsolePresentation`, `callPlatformFunction("nvRegisterConsoleFramebuffer")` | Accept `HyperVGraphicsFramebuffer` (and its subclass `HyperVNVDAGraphicsFramebuffer`) as an NVAccel display head, bound to the passed-through GPU (`10de:28a0` with `HyperVPCIUsesNegotiatedResources`). NVRMFB and NMIntelFB heads keep upstream's path. Only head 0 can be the console. |
| Staging VRAM for the console | `consoleDeviceReady`, `consoleAllocateLocked`, redirects in `askFramebufferForVram`, `nvAccelRmHandles`, `initFramebufferResource` | The console head gets its scan-out surfaces from NVKMS KAPI on the NVRMDisplay nub (`nvkms-kapi`, `gpu-id`, `phys-for-va`), with a 192 MB budget, because the Hyper-V framebuffer has no NVIDIA VRAM of its own. |
| VRAM lifetime | `NVVidMemory::allocPhysical/deallocPhysical/free`, `consoleParkOwner/Unpark/Detach` | Follows upstream's #200 design: on the console route, released VRAM is parked with its owner (`debug.nvaccel_vm_sticky=1`) and returned on reallocation, so a surface does not silently lose its contents. A parked record is never a presentation source. |
| Presentation | `performTransaction`, completed-frame pool (`NvPrepareCompletedS/NvProduceCompletedS/NvCancelCompletedS`), `nvPublicationProduce/Consume/CPU`, `nvConsoleDirectPresent` | Each composed frame is copied by the copy engine from VRAM into a 32 MiB system-memory pool, then handed to the framebuffer's commit (the "private publication" path used by framebuffer 1.0.7). `nvSurfWaitReady` runs before every copy (upstream #196 hazard). A direct path into the aperture is kept for older framebuffers. |
| CPU fallback | `performTransaction` CPU branch | Pages the plane resource off directly without taking the family lock (safe inside the transaction), then a try-lock scan-out sync. |
| ABI layout fix | `accel/iofam/*.h`, `accel/re/*.h`, `nvaccel_stubs.h` | 25 opaque arrays get `alignas(void *)`; `setPurgeable` returns `IOReturn`; a `static_assert` keeps `fPbLogged` from overlapping the IOAccel family's map pointer. The headers are identical in 1.9.0 and 2.3.1, so 2.3.1 still has the overlap upstream. |
| AGDC | `NVRMAGDC/nvrm-agdc.cpp` | `nvdaSupportedFramebuffer` also accepts the Hyper-V framebuffer, so AppleGraphicsDeviceControl sees timing for the console. |
| Boot guard | `configureConsolePresentation` | 2.3.1 turns the driver off after two starts that never reached a display. A VM without a monitor never satisfies NVRMFB's checks, so the console head calls the same `nvrm_guard_display_up` once it has a display pipe. |
| Identity | `Info.plist`, `KMOD_EXPLICIT_DECL` | Version 2.3.1d1 / 2.3.1-hv1. Bundle IDs unchanged. |
| ABI headers | `accel/hyperv/` | Shared structures with the Hyper-V framebuffer and Support (completed-frame ABI, publication lifecycle, exact-row damage). VRAM ABI stays at version 2. |
| Build | `build/hyperv_build.sh` | Builds only NVAccel (macOS 15) and NVRMAGDC against MacKernelSDK and open-gpu-kernel-modules 610.57.04 headers. Upstream's `accel_build.sh` needs a built RM. |

Dropped on the rebase to 2.3.1: our old legacy swap path, diagnostic counters and probes,
and anything upstream had fixed itself (#196, #200).

## Metal plugin (`metal-plugin-fixes.patch`)

All changes are in `plugin/NVMTLObjects.m` / `.h`, marked `HYPERV`.

1. **Render-pass split for self-reads** (`-nvmtlSplitForSelfRead`, called from
   `-setFragmentTexture:atIndex:`). When a draw samples the render pass's own colour target,
   end the pass, put a barrier outside it, and resume with all attachments loaded, restoring
   cull mode, viewport, scissor and depth state. This fixes the black boxes in inactive
   windows; see [black-box-artifact.md](black-box-artifact.md).
2. **Eager page-back of small shared surfaces** (`-nvmtlSurfaceOut`, `NVMTL_EAGER_SURFACE_KB`,
   default 256, `0` disables). After GPU writes to a VRAM-backed IOSurface up to that size, a
   read-only lock makes the kernel page the contents back to system memory at once. Small
   layers (menu-bar items, icons) then cannot come back as zeros after they go volatile.
3. **Live copy for alignment-refused buffer views** (`newTiledTextureWithDescriptor`,
   `nvmtlSurfaceIn/Out`, `nvmtl_surf_dirty`). When the GPU cannot alias a texture over a buffer
   region (offset alignment), upstream makes a one-time copy that never sees later writes. The
   copy is now re-uploaded from the buffer before each use and read back after GPU writes.

## MacHyperVSupport and MacHyperVFramebuffer (`macHyperVSupport.patch`)

Support 1.0.9 is injected by OpenCore; Framebuffer 1.0.7 is in the auxiliary kernel
collection. New shared code is under `publication/` at the repository root.

| Change | Where | Why |
|---|---|---|
| SynIC end-of-message on the owning CPU | `Controller/HyperVControllerInterrupts.cpp` | EOM is a per-virtual-processor MSR; `thread_bind()` does not move the thread until it blocks. Run the write on the owning CPU with interrupts off (upstream PR 12). |
| High MMIO for 64-bit BARs and the config window | `PCIRoot/HyperVPCIRoot.cpp`, `PCIBridge/HyperVPCIBridgePrivate.cpp` | An 8 GiB BAR cannot fit below 4 GiB. 64-bit BARs go to the high ACPI aperture first; 32-bit BARs stay low. |
| Root MMIO ready before PCI clients | `PCIRoot/HyperVPCIRoot.cpp` | The root could be published before its allocators existed; SMP guests raced on it. |
| Negotiated BARs restored | `PCIBridge/HyperVPCIBridge.cpp` | macOS's generic PCI probe caps BARs at 1 GiB and splits an 8 GiB BAR. The bridge rewrites the negotiated registers and publishes matching `assigned-addresses`. |
| Prefetchable range list | `PCIBridge/HyperVPCIBridge.cpp` | A prefetchable BAR in the ordinary range list is silently dropped by IOPCIFamily (it lost the VRAM BAR). |
| Hide L1 PM Substates | `PCIBridge/HyperVPCIBridge.cpp` (`sanitizeVirtualCapabilities`) | The endpoint sits below a synthetic host bridge; IOPCIFamily dereferenced a nonexistent upstream bridge for this capability. |
| MSI response check | `PCIBridge/HyperVPCIBridgePrivate.cpp` | Validate the host's MSI reply and keep the high address bits. |
| Bounded protocol negotiation | `VMBusDevice/HyperVVMBusDevice*.cpp` (`writeInbandPacketWithTimeout`) | After a previous guest instance the host sometimes never answered the first vPCI version query, and boot hung at `NegotiateProtocol`. Each wait is 1 s with an RX-ring drain and a work-loop-serialized cancel, up to 10 resends. |
| Console transport only | `GraphicsBridge/HyperVGraphicsBridge.cpp`, `HyperVGraphicsAperture.hpp`, boot-arg `-hvgfxtransport` | When the GPU owns the framebuffer, the synthetic video nub only provides the aperture. A second display controller made GPUWrangler wait for a framebuffer that never attached. The boot aperture is reserved before PCI allocation. |
| Synthetic video 3.5 | `Graphics/HyperVGraphics*.cpp/.hpp` | Negotiate the video protocol separately from VMBus, like Linux, with a 3.2 fallback. 3.2 caps the framebuffer at 8 MiB. |
| Exact changed-row publication | `Graphics/HyperVGraphicsPublication.cpp`, `publication/` (`HYPERV_PUBLICATION_EXACT_ROWS=1`) | Compare each completed frame with a cached reference in RAM and write only changed rows to the aperture, then notify the host with the full-width row range. The slow aperture is never scanned. Cursor composition is handled in `publication/cursor`. |
| Receive/graphics lock order | `Graphics/HyperVGraphicsPrivate.cpp` | Host feature requests arrive under the VMBus receive gate; they are deferred to the graphics work loop instead of taking the graphics gate (opposite lock order). |
| GPU-associated framebuffer | `MacHyperVFramebuffer/*` | The framebuffer matches the NVIDIA endpoint (`IOPCIMatch 0x28A010DE`, `HyperVPCIUsesNegotiatedResources`) so the accelerator and framebuffer share one PCI provider, while pixels still go through Hyper-V's synthetic video. It exposes NVIDIA's display-pipe scan-out ABI (`nvrm_vram_abi.h`), timing for AGDC, and the private publication commit used by NVAccel. |
| Class name with `NVDA` | `HyperVNVDAGraphicsFramebuffer` in `HyperVGraphicsFramebuffer.hpp/.cpp`, `Info-HyperVNVDA.plist` | CoreDisplay derives a framebuffer's GPU vendor only from its class name. Without `NVDA` the vendor mask was 0, IOPresentment was off, and WindowServer composited in software (no blur or vibrancy). |
| Open/map ordering | `HyperVGraphicsFramebuffer.cpp` | Family open can succeed before the framebuffer map exists; mapping is validated at setup instead of rejecting WindowServer's first open. |

Build: `guest/machypervsupport/build-support.py` and `build-framebuffer.py` (Command Line
Tools only, no Xcode project build).

## MacHyperVHeadlessMetal (`guest/headless-metal/`)

A small kext of ours that matches NVAccel on the passed-through GPU (`10de:28a0` with
negotiated Hyper-V resources). When NVRM reports `nvrm-autogo=up`, it asks
IOAcceleratorFamily to probe the accelerator, sets `MetalPluginName` to `NVMTLDriver` (so
the plugin resolves to `/System/Library/Extensions/NVMTLDriver.bundle`, which WindowServer
is allowed to load), and registers the accelerator. It does not create a display head.

It was written when the Hyper-V framebuffer still sat on the synthetic video device, so
IOFramebuffer never probed the NVIDIA accelerator. It is loaded in the current stack; whether
it is still needed with framebuffer 1.0.7 (which matches the GPU itself) was not re-tested.
