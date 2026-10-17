"""Build MacHyperVHeadlessMetal.kext (0.1.1). Run in the macOS guest:
    MACKERNELSDK=/path/to/MacKernelSDK /usr/bin/python3 build.py
Output: build/MacHyperVHeadlessMetal.kext (unsigned; sign with codesign -s - before use).
"""
import os
import hashlib
import json
import pathlib
import plistlib
import subprocess

root = pathlib.Path(__file__).resolve().parent
sdk = pathlib.Path(os.environ.get('MACKERNELSDK', str(root.parent / 'MacHyperVSupport/MacKernelSDK')))
out = root / 'build'
out.mkdir(exist_ok=True)
flags = ['-target','x86_64-apple-macos12.0','-isysroot',str(sdk),'-I',str(sdk/'Headers'),
         '-std=c++17','-mkernel','-fapple-kext','-fno-exceptions','-fno-rtti',
         '-mno-red-zone','-fno-common','-fno-builtin','-O2','-DKERNEL','-DKERNEL_PRIVATE']
generated = out / 'kmod.cpp'
generated.write_text('''#include <mach/mach_types.h>
#include <mach/kmod.h>
extern "C" {
extern kern_return_t _start(kmod_info_t *, void *);
extern kern_return_t _stop(kmod_info_t *, void *);
kern_return_t headless_start(kmod_info_t *, void *) { return KERN_SUCCESS; }
kern_return_t headless_stop(kmod_info_t *, void *) { return KERN_FAILURE; }
KMOD_EXPLICIT_DECL(org.local.MacHyperVHeadlessMetal, "0.1.1", _start, _stop)
__private_extern__ kmod_start_func_t *_realmain = headless_start;
__private_extern__ kmod_stop_func_t *_antimain = headless_stop;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;
}
''')
objects = []
for source in [root/'HeadlessMetal.cpp', generated]:
    obj = out/(source.stem+'.o')
    subprocess.run(['xcrun','clang++',*flags,'-c',str(source),'-o',str(obj)],check=True)
    objects.append(str(obj))
kext = out/'MacHyperVHeadlessMetal.kext'
binary = kext/'Contents/MacOS/MacHyperVHeadlessMetal'
binary.parent.mkdir(parents=True,exist_ok=True)
subprocess.run(['xcrun','ld','-arch','x86_64','-kext','-static','-undefined','dynamic_lookup',
                '-o',str(binary),*objects,str(sdk/'Library/x86_64/libkmod.a')],check=True)
symbols = subprocess.check_output(['xcrun','nm',str(binary)],text=True)
for symbol in ['_kmod_info','__realmain','__antimain','__start','__stop']:
    if symbol not in symbols: raise RuntimeError('Missing module entry symbol: '+symbol)
identifier='org.local.MacHyperVHeadlessMetal'
info={'CFBundleIdentifier':identifier,'CFBundleName':'MacHyperVHeadlessMetal',
      'CFBundleExecutable':'MacHyperVHeadlessMetal','CFBundlePackageType':'KEXT',
      'CFBundleVersion':'0.1.1','CFBundleShortVersionString':'0.1.1','OSBundleRequired':'Root',
      'OSBundleLibraries':{'com.apple.kpi.iokit':'8.0.0','com.apple.kpi.libkern':'8.0.0','com.apple.kpi.mach':'8.0.0'},
      'IOKitPersonalities':{'HeadlessMetal':{'CFBundleIdentifier':identifier,'IOClass':'MacHyperVHeadlessMetal',
                           'IOProviderClass':'NVAccel','IOMatchCategory':'MacHyperVHeadlessMetal','IOProbeScore':1000}}}
(kext/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
(out/'manifest.json').write_text(json.dumps({'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
   'source_sha256':hashlib.sha256((root/'HeadlessMetal.cpp').read_bytes()).hexdigest(),
   'scope':'Only the 10DE:28A0 endpoint with negotiated Hyper-V PCI resources',
   'activation':'NVRM nvrm-autogo=up'},indent=2))
print('HEADLESS_METAL_BUILD_COMPLETE',binary)
