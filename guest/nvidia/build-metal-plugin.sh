#!/bin/bash
# Build the Metal plugin (NVMTLDriver) from a nvidia-macos-driver v2.3.1 checkout
# with patches/nvidia-macos-driver/metal-plugin-fixes.patch applied.
# Run in the macOS guest with the Xcode command-line tools installed.
#
#   build-metal-plugin.sh <driver-checkout> [<out-dir>]
#
# The compile line is the one upstream's build/build_plugin.sh uses for a
# release build (-DNVMTL_RELEASE=1); that script also requires its own
# LIVE/git workspace layout, which this one does not. The plugin is a single
# translation unit (NVMTLDevice.m includes the other sources).
# VULKAN_HEADERS: a Khronos Vulkan-Headers checkout (v1.4.365 was used).
set -euo pipefail
SRC=$(cd "${1:?driver checkout}" && pwd)
OUT=${2:-$PWD/plugin-out}
VULKAN_HEADERS=${VULKAN_HEADERS:-$HOME/hyperv-build/Vulkan-Headers}
[ -f "$SRC/plugin/NVMTLDevice.m" ] || { echo "STOP: $SRC/plugin/NVMTLDevice.m not found" >&2; exit 1; }
grep -q nvmtlSplitForSelfRead "$SRC/plugin/NVMTLObjects.m" || { echo "STOP: metal-plugin-fixes.patch is not applied" >&2; exit 1; }
[ -d "$VULKAN_HEADERS/include/vulkan" ] || { echo "STOP: set VULKAN_HEADERS to a Vulkan-Headers checkout" >&2; exit 1; }
mkdir -p "$OUT"
cd "$SRC/plugin"
xcrun clang -arch x86_64 -bundle -fobjc-arc -O1 -DNVMTL_RELEASE=1 -Wno-protocol -Wno-incomplete-implementation \
  -I"$VULKAN_HEADERS/include" -o "$OUT/NVMTLDriver" NVMTLDevice.m \
  -framework Foundation -framework Metal -framework IOSurface 2>"$OUT/NVMTLDriver.err" \
  || { grep -A2 ': error:' "$OUT/NVMTLDriver.err" | head -30; exit 1; }
codesign -f -s - "$OUT/NVMTLDriver"
echo "NVMTLDriver $(shasum -a 256 "$OUT/NVMTLDriver" | cut -c1-16) $(otool -l "$OUT/NVMTLDriver" | awk '/uuid/{print $2; exit}')"
echo "$OUT/NVMTLDriver"
