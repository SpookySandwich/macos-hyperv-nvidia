# Black boxes in inactive windows

## Symptom

With the GPU-composited desktop working, inactive windows showed sharp-cornered black
rectangles where text should be: behind labels in System Settings, and inside the white
"Continue" button of Notes' "Welcome to Notes" window once another app was active. The
active window always looked right.

- It often appeared right after login, and reliably on the first drag of the active window
  across the inactive one.
- It stayed until the inactive app redrew (activating Notes fixed it; deactivating it again
  was fine until the next exposure).
- A window-only capture (`screencapture -l <window>`) also showed it, so the black was in what
  WindowServer composed for the window, not in the copy to the Hyper-V display.

## What ruled things out

- The black box was the size of the button's title quad (about 16-17 px tall inside a 27 px
  bezel), not whole rows. The window surface is pitch-linear with one 4 KiB page per row, so
  anything that loses memory (stale or zero system-memory upload, kernel page-off, VRAM parking)
  would corrupt full-width bands. The box was drawn.
- Turning off buffer-texture recycling, making GPU system memory uncached, CPU load, a cold
  shader cache and the alignment live-copy fix each made no difference.

## Root cause

WindowServer builds a window's backing surface again when its app becomes inactive (a new
IOSurface, so its initial content is zero). That pass ends with a draw, with blending off,
that samples the pass's own colour target: the inactive "vibrant" text is drawn with
shader-side blending that reads the destination. Core Animation issues a
`memoryBarrierWithScope:` before it.

The Metal plugin implements that barrier as a `vkCmdPipelineBarrier` inside the active Vulkan
render pass. On this stack that did not make the earlier draws in the same pass visible to the
sampler. The draw read the pass-start contents, which are zero on a fresh surface, and wrote
opaque black over the text quad. Nothing showed it until that region of the screen was
recomposited from the window surface, which is what a drag over it does.

A trace of a whole boot showed the rebuild of the Notes window surface with the self-read, the
next surface copying that region forward, and black after the first drag. A diagnostic build
that added a second in-pass barrier before such draws did not help, which confirmed that an
in-pass barrier is not enough.

## Fix

`-nvmtlSplitForSelfRead` in `plugin/NVMTLObjects.m` (see
`patches/nvidia-macos-driver/metal-plugin-fixes.patch`). When a fragment texture is the
encoder's own colour target, the encoder:

1. ends the render pass,
2. issues the barrier outside it,
3. resumes the pass with all attachments loaded (`NVMTL_LOAD_ALL`),
4. restores cull mode, viewport, scissor and depth/stencil state.

This is the same split the plugin already used for its mesh path. The cost is one pass split
per self-reading draw, only in passes that bind their own target.

## Result (visual check)

Without the fix, the first drag after login produced the black box in 5 of 5 boots. With the
fix, 2 of 2 boots were clean at login, after the first drag and after a long sweep. These are
visual checks, not an automated test.
