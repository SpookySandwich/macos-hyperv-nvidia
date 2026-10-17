#!/bin/bash
# Undo install-2.3.1.sh from its recovery folder. Run as root (boot without
# the GPU first if the desktop is broken), then reboot.
# Usage: rollback-2.3.1.sh /Users/Shared/hyperv-recovery/rebase-2.3.1-<stamp>
set -euo pipefail
rec=${1:?recovery folder}
ext=/Library/Extensions
sle=/System/Library/Extensions
for k in NVRM NVRMFB NVAccel NVRMAGDC; do rm -rf "$ext/$k.kext"; ditto "$rec/kexts/$k.kext" "$ext/$k.kext"; done
cp "$rec/AuxiliaryKernelExtensions.kc" /Library/KernelCollections/AuxiliaryKernelExtensions.kc
system_device=$(diskutil info -plist / | plutil -extract DeviceIdentifier raw -o - - | sed -E 's/s[0-9]+$//')
stage=/Users/Shared/hyperv-system-gpu-stage
mkdir -p "$stage"
mount -t apfs -o nobrowse "/dev/$system_device" "$stage"
for b in NVMTLDriver.bundle NVIDIAShared.bundle nvmtl; do rm -rf "$stage$sle/$b"; ditto "$rec/system/$b" "$stage$sle/$b"; done
[ -f "$rec/system/nvmtl-allow.txt" ] && cp "$rec/system/nvmtl-allow.txt" "$stage$sle/nvmtl-allow.txt"
bless --folder "$stage/System/Library/CoreServices" --bootefi --create-snapshot
diskutil unmount "$stage"
cp "$rec/gpubundles-nvmtl-allow.txt" /Library/GPUBundles/nvmtl-allow.txt
efi=$(mktemp -d)
mount -t msdos "${EFI_DEV:-/dev/disk0s2}" "$efi"   # EFI_DEV: the OpenCore EFI partition
cp "$rec/config.plist" "$efi/EFI/OC/config.plist"
nvram boot-args="$(/usr/libexec/PlistBuddy -c 'Print :NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args' "$efi/EFI/OC/config.plist")"
diskutil unmount "$efi" >/dev/null
echo "ROLLED_BACK from $rec"
