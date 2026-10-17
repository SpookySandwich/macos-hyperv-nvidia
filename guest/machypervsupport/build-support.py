"""Build MacHyperVSupport 1.0.9 (MacHyperVSupportMonterey.kext) with the Apple Command Line Tools (no full Xcode).

Run in the macOS guest from a MacHyperVSupport checkout at acidanthera cafcd34 with
patches/macHyperVSupport.patch applied, plus MacKernelSDK/ and Lilu.kext/ (DEBUG) in that
checkout, as upstream's own build expects:
    HYPERV_SOURCE_ROOT=/path/to/MacHyperVSupport /usr/bin/python3 build-support.py
Output: <root>/build-local/MacHyperVSupportMonterey.kext (unsigned; sign with codesign -s - before use).
"""
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess

root = pathlib.Path(os.environ.get('HYPERV_SOURCE_ROOT', str(pathlib.Path.home() / 'hyperv-build/MacHyperVSupport')))
project = (root / 'MacHyperVSupport.xcodeproj/project.pbxproj').read_text()
phase = re.search(r'41BF4608288CDF1200813670 /\* Sources \*/ = \{(.*?)\n\t\t\};', project, re.S).group(1)
names = re.findall(r'/\* (\S+\.cpp) in Sources \*/', phase)
files = []
for name in names:
    candidates = list((root / 'MacHyperVSupport').rglob(name))
    if name == 'plugin_start.cpp':
        candidates = list((root / 'Lilu.kext/Contents/Resources').rglob(name))
    if len(candidates) != 1:
        raise RuntimeError(f'{name}: expected one source, got {candidates}')
    files.append(candidates[0])

files += [root/'MacHyperVSupport/Graphics/HyperVGraphicsPublication.cpp']
publication = root/'publication'
files += [publication/name for name in ['HyperVPublicationTransport.cpp','PublicationOwnerController.cpp',
  'HyperVPublicationKernelMemory.cpp','core/publication-coordinator.c','core/vendor/exact-row-damage.c','cursor/owned_cursor.c']]
out = root / 'build-local' 
objects = out / 'objects'
objects.mkdir(parents=True, exist_ok=True)
toolroot = os.environ.get('HYPERV_CLT_ROOT')
compiler = [str(pathlib.Path(toolroot) / 'usr/bin/clang++')] if toolroot else ['xcrun', 'clang++']
linker = [str(pathlib.Path(toolroot) / 'usr/bin/ld')] if toolroot else ['xcrun', 'ld']
# User-space SDK headers conflict with kernel IOKit types.
sdk = str(root / 'MacKernelSDK')
flags = ['-target', 'x86_64-apple-macos12.0', '-isysroot', sdk,
         '-std=gnu++14', '-mkernel', '-fapple-kext', '-fno-exceptions', '-fno-rtti',
         '-mno-red-zone', '-fno-common', '-fno-builtin', '-fno-asynchronous-unwind-tables',
         '-mmmx', '-msse', '-msse2', '-msse3', '-mssse3', '-O1', '-g',
         '-DKERNEL', '-DKERNEL_PRIVATE', '-DDEBUG=1', '-DMODULE_VERSION=1.0.9',
         '-DPRODUCT_NAME=MacHyperVSupportMonterey', '-Wno-deprecated-declarations',
         '-Wno-unknown-warning-option', '-Wno-ossharedptr-misuse']
for inc in [root / 'MacKernelSDK/Headers', root / 'Lilu.kext/Contents/Resources',
            root / 'MacHyperVSupport']:
    flags.extend(['-I', str(inc)])
for inc in (root / 'MacHyperVSupport').rglob('*'):
    if inc.is_dir():
        flags.extend(['-I', str(inc)])

flags += ['-I', str(publication), '-DHYPERV_PUBLICATION_EXACT_ROWS=1']
compile_commands = []
objfiles = []
for index, src in enumerate(files, 1):
    obj = objects / (src.stem + '.o')
    print(f'[{index}/{len(files)}] {src.name}', flush=True)
    command = [*compiler, *flags, *(['-mno-sse','-mno-sse2','-mno-mmx','-x','c++'] if (publication in src.parents or src.name=='HyperVGraphicsPublication.cpp') else []), '-c', str(src), '-o', str(obj)]
    compile_commands.append(command)
    subprocess.run(command, check=True)
    objfiles.append(str(obj))

# Xcode normally generates this translation unit for a kernel extension.
# libkmod alone does not provide kmod_info or hook the driver's entry points.
kmod_source = out / 'kmod-generated.cpp'
kmod_source.write_text('''#include <mach/mach_types.h>
#include <mach/kmod.h>
extern "C" {
extern kern_return_t _start(kmod_info_t *, void *);
extern kern_return_t _stop(kmod_info_t *, void *);
extern kern_return_t MacHyperVSupportMonterey_kern_start(kmod_info_t *, void *);
extern kern_return_t MacHyperVSupportMonterey_kern_stop(kmod_info_t *, void *);
KMOD_EXPLICIT_DECL(fish.goldfish64.MacHyperVSupport, "1.0.9", _start, _stop)
__private_extern__ kmod_start_func_t *_realmain = MacHyperVSupportMonterey_kern_start;
__private_extern__ kmod_stop_func_t *_antimain = MacHyperVSupportMonterey_kern_stop;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;
}
''')
kmod_object = objects / 'kmod-generated.o'
command = [*compiler, *flags, '-c', str(kmod_source), '-o', str(kmod_object)]
compile_commands.append(command)
subprocess.run(command, check=True)
objfiles.append(str(kmod_object))

kext = out / 'MacHyperVSupportMonterey.kext'
shutil.copytree(root / 'Template.kext', kext, dirs_exist_ok=True)
(kext / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
binary = kext / 'Contents/MacOS/MacHyperVSupportMonterey'
subprocess.run([*linker, '-arch', 'x86_64', '-kext', '-static', '-undefined',
                'dynamic_lookup', '-o', str(binary), *objfiles,
                str(root / 'MacKernelSDK/Library/x86_64/libkmod.a')], check=True)
nm = [str(pathlib.Path(toolroot) / 'usr/bin/nm')] if toolroot else ['xcrun', 'nm']
symbols = subprocess.check_output([*nm, str(binary)], text=True)
required_symbols = ('_kmod_info', '__realmain', '__antimain', '__start', '__stop',
                    '_MacHyperVSupportMonterey_kern_start', '_MacHyperVSupportMonterey_kern_stop')
for symbol in required_symbols:
    if not re.search(r'^[0-9a-fA-F]+\s+[A-Za-z]\s+' + re.escape(symbol) + r'$', symbols, re.M):
        raise RuntimeError(f'Missing defined kernel module symbol: {symbol}')
info = kext / 'Contents/Info.plist'
with info.open('rb') as f:
    p = plistlib.load(f)
p['CFBundleVersion'] = p['CFBundleShortVersionString'] = '1.0.9'
with info.open('wb') as f:
    plistlib.dump(p, f, sort_keys=False)
manifest = {'compile_commands': compile_commands, 'exact_rows_macro': 1, 'compiler': subprocess.check_output([*compiler, '--version'], text=True),
            'sources': {str(src): hashlib.sha256(src.read_bytes()).hexdigest()
                        for src in files}, 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'module_entry_points_verified': list(required_symbols),
            'generated_kmod_sha256': hashlib.sha256(kmod_source.read_bytes()).hexdigest(),
            'fixes': ['SynIC EOM acknowledgement on owning CPU (upstream PR 12)',
                      'High MMIO allocation for 64-bit PCI BARs and config window',
                      'Wait for root MMIO initialization before PCI clients start',
                      'Hide host-owned L1 PM Substates on the synthetic PCI bus',
                      'Publish prefetchable GPU BARs in the correct PCI range list',
                      'Publish negotiated vPCI apertures beyond Apple generic 1 GiB BAR limit',
                      'Validate MSI host response and preserve its high address bits',
                      'Expose the synthetic console aperture as transport when the assigned GPU owns the framebuffer']}
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2))
subprocess.run(['file', str(binary)], check=True)
print('BUILD_COMPLETE', flush=True)
