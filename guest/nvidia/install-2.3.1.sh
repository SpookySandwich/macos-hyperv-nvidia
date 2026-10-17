#!/bin/bash
# Install upstream 2.3.1 (prebuilt NVRM, NVRMFB, Metal bundles) plus our
# Hyper-V NVAccel/NVRMAGDC 2.3.1d1. Everything replaced is copied to $rec first.
# Run as root in the guest; reboot afterwards.
# Inputs (see docs/building.md): the 2.3.1 release pkgroot unpacked under
# $build/rebase-2.3.1/release/pkgroot, and NVAccel/NVRMAGDC built by
# build/hyperv_build.sh into $build/rebase-2.3.1-out. To ship the patched Metal
# plugin, copy the output of build-metal-plugin.sh over
# $pkg/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver first.
set -euo pipefail
build=${HYPERV_BUILD_ROOT:-/Users/${SUDO_USER:?run with sudo from the build user}/hyperv-build}
pkg=$build/rebase-2.3.1/release/pkgroot
out=$build/rebase-2.3.1-out
rec=/Users/Shared/hyperv-recovery/rebase-2.3.1-$(date +%Y%m%d-%H%M%S)
ext=/Library/Extensions
sle=/System/Library/Extensions
mkdir -p "$rec/kexts" "$rec/system"

# 1. Back up kernel drivers, kernel collection, Metal bundles, boot config.
for k in NVRM NVRMFB NVAccel NVRMAGDC; do ditto "$ext/$k.kext" "$rec/kexts/$k.kext"; done
cp /Library/KernelCollections/AuxiliaryKernelExtensions.kc "$rec/"
for b in NVMTLDriver.bundle NVIDIAShared.bundle nvmtl; do ditto "$sle/$b" "$rec/system/$b"; done
cp "$sle/nvmtl-allow.txt" "$rec/system/" 2>/dev/null || true
cp /Library/GPUBundles/nvmtl-allow.txt "$rec/gpubundles-nvmtl-allow.txt"
diskutil apfs listSnapshots / > "$rec/root-snapshots-before.txt"
efi=$(mktemp -d)
mount -t msdos "${EFI_DEV:-/dev/disk0s2}" "$efi"   # EFI_DEV: the OpenCore EFI partition
cp "$efi/EFI/OC/config.plist" "$rec/config.plist"
echo "backup done: $rec"

# 2. Kernel drivers + auxiliary kernel collection (restore on failure).
restore_kexts() { for k in NVRM NVRMFB NVAccel NVRMAGDC; do rm -rf "$ext/$k.kext"; ditto "$rec/kexts/$k.kext" "$ext/$k.kext"; done; }
for k in NVRM NVRMFB; do rm -rf "$ext/$k.kext"; ditto "$pkg/Library/Extensions/$k.kext" "$ext/$k.kext"; done
for k in NVAccel NVRMAGDC; do rm -rf "$ext/$k.kext"; ditto "$out/$k.kext" "$ext/$k.kext"; done
for k in NVRM NVRMFB NVAccel NVRMAGDC; do chown -R root:wheel "$ext/$k.kext"; chmod -R go-w "$ext/$k.kext"; done
next=/Library/KernelCollections/AuxiliaryKernelExtensions.rebase-next.kc
if ! kmutil create -n aux \
  -B /System/Library/KernelCollections/BootKernelExtensions.kc \
  -S /System/Library/KernelCollections/SystemKernelExtensions.kc \
  -A "$next" --allow-missing-kdk -x \
  -p "$ext/MacHyperVFramebuffer.kext" \
  -p "$ext/NVRM.kext" -p "$ext/NVRMFB.kext" \
  -p "$ext/NVRMAGDC.kext" -p "$ext/NVAccel.kext" \
  -p "$ext/MacHyperVHeadlessMetal.kext" > "$rec/kmutil.log" 2>&1; then
  restore_kexts; tail -40 "$rec/kmutil.log"; diskutil unmount "$efi" >/dev/null; exit 1
fi
mv "$next" /Library/KernelCollections/AuxiliaryKernelExtensions.kc
kmutil inspect -V release --show-mach-header -A /Library/KernelCollections/AuxiliaryKernelExtensions.kc 2>/dev/null \
  | grep -E "com\.(nullmoth|fish|org)" | head -20 || true

# 3. Writable shared shader caches on the data volume (WindowServer only).
cache=/Library/NullMoth/shader-cache
mkdir -p "$cache/aircache" "$cache/spvcache"
chown -R _windowserver:wheel "$cache/aircache" "$cache/spvcache"
chmod 0755 "$cache" "$cache/aircache" "$cache/spvcache"

# 4. Metal bundles into a new root snapshot (the previous one stays bootable).
csrutil authenticated-root status | grep -q disabled
system_device=$(diskutil info -plist / | plutil -extract DeviceIdentifier raw -o - - | sed -E 's/s[0-9]+$//')
stage=/Users/Shared/hyperv-system-gpu-stage
mkdir -p "$stage"
mount -t apfs -o nobrowse "/dev/$system_device" "$stage"
dest="$stage$sle"
for b in NVMTLDriver.bundle NVIDIAShared.bundle nvmtl; do rm -rf "$dest/$b"; ditto "$pkg/Library/GPUBundles/$b" "$dest/$b"; done
ln -s "$cache/aircache" "$dest/nvmtl/aircache"
ln -s "$cache/spvcache" "$dest/nvmtl/spvcache"
cp "$pkg/Library/GPUBundles/nvmtl-allow.txt" "$dest/nvmtl-allow.txt"
for b in NVMTLDriver.bundle NVIDIAShared.bundle nvmtl; do chown -R root:wheel "$dest/$b"; chmod -R go-w,a+rX "$dest/$b"; done
chmod 644 "$dest/nvmtl-allow.txt"
bless --folder "$stage/System/Library/CoreServices" --bootefi --create-snapshot
diskutil apfs listSnapshots "$stage" > "$rec/root-snapshots-after.txt"
diskutil unmount "$stage"
cp "$pkg/Library/GPUBundles/nvmtl-allow.txt" /Library/GPUBundles/nvmtl-allow.txt
chmod 644 /Library/GPUBundles/nvmtl-allow.txt

# 5. Boot flag: stay on the copy path (no zero-copy scan-out on a VM).
cfg="$efi/EFI/OC/config.plist"
key=NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args
args=$(/usr/libexec/PlistBuddy -c "Print :$key" "$cfg")
case " $args " in *" -nvrmnoflip "*) ;; *) /usr/libexec/PlistBuddy -c "Set :$key $args -nvrmnoflip" "$cfg" ;; esac
/usr/libexec/PlistBuddy -c "Print :$key" "$cfg"
# OpenCore keeps an existing NVRAM value unless its Delete list names it; set both.
nvram boot-args="$(/usr/libexec/PlistBuddy -c "Print :$key" "$cfg")"
diskutil unmount "$efi" >/dev/null
echo "INSTALLED_2.3.1 recovery=$rec"
