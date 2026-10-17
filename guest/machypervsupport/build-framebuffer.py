"""Build MacHyperVFramebuffer 1.0.7 (class HyperVNVDAGraphicsFramebuffer) with the Apple Command Line Tools.

Run in the macOS guest from the same patched MacHyperVSupport checkout as build-support.py:
    HYPERV_SOURCE_ROOT=/path/to/MacHyperVSupport /usr/bin/python3 build-framebuffer.py
Output: <root>/build-framebuffer/MacHyperVFramebuffer.kext (unsigned; sign with codesign -s - before use).

The framebuffer uses Hyper-V's synthetic video device as its transport, but its personality
matches the passed-through NVIDIA endpoint (10DE:28A0 with negotiated Hyper-V PCI resources),
so the accelerator and the framebuffer sit beneath one real PCI provider. The Info.plist
(MacHyperVFramebuffer/Info-HyperVNVDA.plist, added by the patch) is the one deployed with 1.0.7.
Edit IOPCIMatch there for a different GPU.
"""
import hashlib
import json
import os
import pathlib
import plistlib
import subprocess

root = pathlib.Path(os.environ.get('HYPERV_SOURCE_ROOT', str(pathlib.Path.home() / 'hyperv-build/MacHyperVSupport')))
out = root / 'build-framebuffer'
out.mkdir(exist_ok=True)
sdk = root / 'MacKernelSDK'
flags = ['-target','x86_64-apple-macos12.0','-isysroot',str(sdk),'-std=gnu++14',
         '-mkernel','-fapple-kext','-fno-exceptions','-fno-rtti','-mno-red-zone','-fno-common',
         '-fno-builtin','-O1','-DKERNEL','-DKERNEL_PRIVATE','-DPRODUCT_NAME=MacHyperVFramebuffer',
         '-DMODULE_VERSION=1.0.7','-Wno-deprecated-declarations']
for path in [sdk/'Headers',root/'Lilu.kext/Contents/Resources',root/'MacHyperVFramebuffer',
             root/'MacHyperVSupport',*sorted(p for p in (root/'MacHyperVSupport').rglob('*') if p.is_dir())]:
    flags += ['-I',str(path)]
flags += ['-I',str(root/'publication')]
generated = out/'kmod.cpp'
generated.write_text('''#include <mach/mach_types.h>
#include <mach/kmod.h>
extern "C" {
extern kern_return_t _start(kmod_info_t *, void *);
extern kern_return_t _stop(kmod_info_t *, void *);
kern_return_t framebuffer_start(kmod_info_t *, void *) { return KERN_SUCCESS; }
kern_return_t framebuffer_stop(kmod_info_t *, void *) { return KERN_FAILURE; }
KMOD_EXPLICIT_DECL(fish.goldfish64.MacHyperVFramebuffer, "1.0.7", _start, _stop)
__private_extern__ kmod_start_func_t *_realmain = framebuffer_start;
__private_extern__ kmod_stop_func_t *_antimain = framebuffer_stop;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;
}
''')
sources = [root/'MacHyperVFramebuffer/HyperVGraphicsFramebuffer.cpp',
           root/'MacHyperVFramebuffer/HyperVGraphicsFramebufferPrivate.cpp',generated,
           root/'MacHyperVFramebuffer/HyperVGraphicsFramebufferPublication.cpp',
           root/'MacHyperVFramebuffer/PFFramebufferMemory.cpp']
objects = []
for source in sources:
    obj = out/(source.stem+'.o')
    subprocess.run(['xcrun','clang++',*flags,'-c',str(source),'-o',str(obj)],check=True)
    objects.append(str(obj))
kext = out/'MacHyperVFramebuffer.kext'
binary = kext/'Contents/MacOS/MacHyperVFramebuffer'
binary.parent.mkdir(parents=True,exist_ok=True)
subprocess.run(['xcrun','ld','-arch','x86_64','-kext','-static','-undefined','dynamic_lookup',
                '-o',str(binary),*objects,str(sdk/'Library/x86_64/libkmod.a')],check=True)
symbols=subprocess.check_output(['xcrun','nm',str(binary)],text=True)
for symbol in ['_kmod_info','__realmain','__antimain','__start','__stop']:
    if symbol not in symbols: raise RuntimeError('Missing kernel entry symbol: '+symbol)
info=plistlib.loads((root/'MacHyperVFramebuffer/Info-HyperVNVDA.plist').read_bytes())
info['CFBundleVersion']=info['CFBundleShortVersionString']='1.0.7'
personality=info['IOKitPersonalities']['HyperVGraphicsFramebuffer']
# CoreDisplay needs "NVDA" in the class name to enable GPU presentation.
assert personality['IOClass']=='HyperVNVDAGraphicsFramebuffer'
(kext/'Contents/Info.plist').write_bytes(plistlib.dumps(info,sort_keys=False))
(out/'manifest.json').write_text(json.dumps({'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
    'info_sha256':hashlib.sha256((kext/'Contents/Info.plist').read_bytes()).hexdigest(),
    'version':'1.0.7','io_class':personality['IOClass'],'pci_match':personality.get('IOPCIMatch'),
    'source_sha256':{str(s.relative_to(root)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}},indent=2))
print('FRAMEBUFFER_BUILD_PASS',binary)
