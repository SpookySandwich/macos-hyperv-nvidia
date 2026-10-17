# Display options

The RTX 4060 renders the desktop, but how the picture reaches your eyes is the weak part of
this setup. These are the routes we looked at.

## 1. Hyper-V console (default)

The path described in [architecture.md](architecture.md): composed frames are copied out of
GPU memory into the Hyper-V synthetic framebuffer and shown by `vmconnect` or the Windows app,
both of which use Hyper-V's RDP-based console protocol.

- Works with no extra hardware, and the GPU handoff stays fully scripted.
- Measured on a small changing marker at 3200x2000 guest resolution: exact changed-row
  publication raised visible updates from 1.8-2.7 FPS (full-frame publication) to about 82 FPS,
  and the median delay from submission to host composition fell from 45-47 ms to 27-28 ms.
  This is a narrow test, not a full-screen or input-latency measurement.
- Still laggy in real use: window drags and full-screen animation are not smooth. The remaining
  cost is in the guest copy and comparison, and in the host's console encoding and viewer.
- The synthetic framebuffer size is set from the host with `Set-VMVideo` (the app uses
  3200x2000; Hyper-V video protocol 3.5 is required for more than 8 MiB).

## 2. Streaming (Sunshine on macOS, Moonlight on Windows)

Evaluated and working. Motion is smooth, but the picture looks like video: text and fine
detail show compression, and it adds an encoder in the loop.

- Hardware encoding is not available: upstream keeps NVENC off on every GPU older than
  Blackwell because its encoder output was corrupt, so H.264/HEVC encode falls back to Apple's
  software encoder or libx264. Other users report the same for Ada cards.
- If you use it anyway: Sunshine's software encoder supports 4:4:4 chroma (enable "YUV 4:4:4"
  in Moonlight), which helps text; stream at the client's exact resolution.

## 3. A monitor on the RTX 4060's HDMI port

The laptop's internal panel is wired to the Intel GPU. The RTX 4060 reports one external
connector, the HDMI port. A monitor on that port would be driven by the GPU directly through
upstream's own framebuffer (NVRMFB), which is upstream's normal, supported path and avoids all
copies. We did not test it in the VM. One known interaction: if NVRMFB publishes a head before
the Hyper-V console head, the console would become a duplicate without a display pipe.

## 4. MUX / dGPU-only mode

Not available on this laptop. The firmware's ACPI code implements only the iGPU-mode calls
(hybrid, iGPU-only, auto); it has no handler for the MUX / G-Sync calls. Upstream's `nvrmmux=1`
(an ACPI switch found on some Advanced Optimus laptops) therefore does not apply, and the
internal panel always stays on the Intel GPU.

## 5. Upstream "headless" mode

Upstream 1.12+ can treat a GPU without a display as a second Metal device for apps, leaving
WindowServer on the GPU that owns the display. Here that would be the synthetic framebuffer
with a CPU compositor, which is worse than the console path above. Not used.
