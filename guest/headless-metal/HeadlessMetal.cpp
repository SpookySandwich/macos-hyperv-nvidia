#include <IOKit/IOService.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/graphics/IOGraphicsTypes.h>
#include <libkern/c++/OSString.h>
#include <libkern/c++/OSBoolean.h>
#include <libkern/c++/OSData.h>

class MacHyperVHeadlessMetal : public IOService {
  OSDeclareDefaultStructors(MacHyperVHeadlessMetal)
  IOService *accelerator = nullptr;
  IOService *gpu = nullptr;
  IOWorkLoop *loop = nullptr;
  IOTimerEventSource *timer = nullptr;
  unsigned attempts = 0;
  bool published = false;
  void checkReady(IOTimerEventSource *) {
    if (published) { return; }
    bool ready = false;
    OSIterator *children = gpu->getChildIterator(gIOServicePlane);
    if (children) {
      while (IORegistryEntry *entry = static_cast<IORegistryEntry *>(children->getNextObject())) {
        if (strcmp(entry->getMetaClass()->getClassName(), "NVRM") != 0) { continue; }
        OSString *state = OSDynamicCast(OSString, entry->getProperty("nvrm-autogo"));
        ready = state && state->isEqualTo("up");
        break;
      }
      children->release();
    }
    if (ready) {
      // IOFramebuffer normally sends this probe to the accelerator beneath
      // its PCI parent. Hyper-V's framebuffer has a separate synthetic PCI
      // parent, so it never probes the physical NVIDIA accelerator. Ask the
      // real IOAcceleratorFamily service to perform its normal registration;
      // do not invent an IOAccelIndex or an NVIDIA display head.
      IOReturn probeStatus = accelerator->requestProbe(kIOFBUserRequestProbe);
      setProperty("AcceleratorProbeStatus", static_cast<UInt64>(probeStatus), 32);
      if (OSObject *index = accelerator->getProperty("IOAccelIndex")) {
        setProperty("RegisteredAcceleratorIndex", index);
      }
      // GPU execution and physical display initialization are independent.
      // The unchanged NVMTL plug-in can render offscreen once RM/GSP is up.
      // Hyper-V retains its own framebuffer; no display machine is fabricated.
      accelerator->setProperty("MetalPluginName", "NVMTLDriver");
      accelerator->setProperty("IOGLBundleName", "AppleMetalOpenGLRenderer");
      accelerator->setProperty("MacHyperVHeadlessMetal", true);
      accelerator->registerService();
      setProperty("State", "MetalPublishedAfterGpuInitialization");
      published = true;
      IOLog("MacHyperVHeadlessMetal: published NVMTL after NVRM initialization, accelerator probe 0x%x\n", probeStatus);
      return;
    }
    if (++attempts >= 360) { setProperty("State", "GpuInitializationTimeout"); return; }
    timer->setTimeoutMS(1000);
  }
public:
  bool start(IOService *provider) override {
    if (strcmp(provider->getMetaClass()->getClassName(), "NVAccel") != 0) { return false; }
    IOService *candidate = provider->getProvider();
    if (!candidate || candidate->getProperty("HyperVPCIUsesNegotiatedResources") != kOSBooleanTrue) { return false; }
    OSData *vendor = OSDynamicCast(OSData, candidate->getProperty("vendor-id"));
    OSData *device = OSDynamicCast(OSData, candidate->getProperty("device-id"));
    if (!vendor || vendor->getLength() != 4 || !device || device->getLength() != 4) { return false; }
    if (*static_cast<const UInt32 *>(vendor->getBytesNoCopy()) != 0x10DE ||
        *static_cast<const UInt32 *>(device->getBytesNoCopy()) != 0x28A0) { return false; }
    if (!IOService::start(provider)) { return false; }
    accelerator = provider; accelerator->retain(); gpu = candidate; gpu->retain();
    loop = IOWorkLoop::workLoop();
    if (loop) { timer = IOTimerEventSource::timerEventSource(this, OSMemberFunctionCast(IOTimerEventSource::Action, this, &MacHyperVHeadlessMetal::checkReady)); }
    if (!loop || !timer || loop->addEventSource(timer) != kIOReturnSuccess) { stop(provider); return false; }
    setProperty("State", "WaitingForNvrmGpuInitialization");
    registerService();
    timer->setTimeoutMS(1000);
    return true;
  }
  void stop(IOService *provider) override {
    if (timer) { timer->cancelTimeout(); if (loop) { loop->removeEventSource(timer); } timer->release(); timer = nullptr; }
    if (loop) { loop->release(); loop = nullptr; }
    if (accelerator) { accelerator->release(); accelerator = nullptr; }
    if (gpu) { gpu->release(); gpu = nullptr; }
    IOService::stop(provider);
  }
};
OSDefineMetaClassAndStructors(MacHyperVHeadlessMetal, IOService)
