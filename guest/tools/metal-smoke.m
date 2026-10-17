#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/message.h>
#include <math.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
        for (id<MTLDevice> d in devices) printf("DEVICE: %s registry=%llu\n", d.name.UTF8String, d.registryID);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (argc > 1 && strcmp(argv[1], "--direct-driver") == 0) {
            puts("DIAGNOSTIC_DIRECT_DRIVER (bypasses normal device discovery)");
            NSError *bundleError = nil;
            NSBundle *bundle = [NSBundle bundleWithPath:@"/Library/GPUBundles/NVMTLDriver.bundle"];
            if (![bundle loadAndReturnError:&bundleError]) {
                fprintf(stderr,"DRIVER_BUNDLE_ERROR: %s\n",bundleError.description.UTF8String);
                return 11;
            }
            Class driver = NSClassFromString(@"NVMTLDevice");
            io_service_t accelerator = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NVAccel"));
            if (!driver || !accelerator) { fprintf(stderr,"NO_NVIDIA_ACCELERATOR_CLASS_OR_SERVICE\n"); return 12; }
            id instance = ((id (*)(id, SEL))objc_msgSend)((id)driver, sel_registerName("alloc"));
            device = (id<MTLDevice>)((id (*)(id, SEL, mach_port_t))objc_msgSend)(instance, sel_registerName("initWithAcceleratorPort:"), accelerator);
            IOObjectRelease(accelerator);
        }
        if (!device) { fprintf(stderr, "NO_METAL_DEVICE\n"); return 2; }
        printf("DEFAULT: %s\n", device.name.UTF8String);
        id<MTLCommandQueue> queue = [device newCommandQueue];
        NSError *error = nil;
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void twice(device const float *a [[buffer(0)]], device float *b [[buffer(1)]], uint i [[thread_position_in_grid]]) { b[i] = a[i] * 2.0f; }\n"
        "vertex float4 vertex_main(uint i [[vertex_id]]) { const float2 p[3] = {float2(-1,-1),float2(1,-1),float2(0,1)}; return float4(p[i],0,1); }\n"
        "fragment float4 fragment_main() { return float4(1,0,0,1); }\n";
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        if (!library) { fprintf(stderr, "SHADER_ERROR: %s\n", error.description.UTF8String); return 3; }
        id<MTLComputePipelineState> compute = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"twice"] error:&error];
        if (!compute) { fprintf(stderr, "COMPUTE_PIPELINE_ERROR: %s\n", error.description.UTF8String); return 4; }
        const NSUInteger count = 1024;
        id<MTLBuffer> input = [device newBufferWithLength:count*sizeof(float) options:MTLResourceStorageModeShared];
        id<MTLBuffer> output = [device newBufferWithLength:count*sizeof(float) options:MTLResourceStorageModeShared];
        if (!input || !output) return 5;
        for (NSUInteger i=0;i<count;i++) ((float*)input.contents)[i] = i * 0.25f;
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:compute];
        [encoder setBuffer:input offset:0 atIndex:0];
        [encoder setBuffer:output offset:0 atIndex:1];
        [encoder dispatchThreads:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(32,1,1)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted) { fprintf(stderr,"COMPUTE_COMMAND_ERROR: %s\n",command.error.description.UTF8String); return 6; }
        NSUInteger bad=0;
        for (NSUInteger i=0;i<count;i++) if (fabsf(((float*)output.contents)[i] - i * 0.5f) > 0.0001f) bad++;
        printf("COMPUTE_BAD_VALUES: %lu/%lu\n",bad,count);
        if (bad) return 7;

        MTLRenderPipelineDescriptor *pipeline = [MTLRenderPipelineDescriptor new];
        pipeline.vertexFunction = [library newFunctionWithName:@"vertex_main"];
        pipeline.fragmentFunction = [library newFunctionWithName:@"fragment_main"];
        pipeline.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> render = [device newRenderPipelineStateWithDescriptor:pipeline error:&error];
        if (!render) { fprintf(stderr,"RENDER_PIPELINE_ERROR: %s\n",error.description.UTF8String); return 8; }
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
        td.storageMode=MTLStorageModePrivate; td.usage=MTLTextureUsageRenderTarget;
        id<MTLTexture> texture=[device newTextureWithDescriptor:td];
        id<MTLBuffer> pixels=[device newBufferWithLength:64*64*4 options:MTLResourceStorageModeShared];
        MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=texture;
        pass.colorAttachments[0].loadAction=MTLLoadActionClear;
        pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,1,1);
        command=[queue commandBuffer];
        id<MTLRenderCommandEncoder> re=[command renderCommandEncoderWithDescriptor:pass];
        [re setRenderPipelineState:render]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding];
        id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
        [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(64,64,1) toBuffer:pixels destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:16384];
        [blit endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted) { fprintf(stderr,"RENDER_COMMAND_ERROR: %s\n",command.error.description.UTF8String); return 9; }
        unsigned char *p=pixels.contents, *center=p+(32*64+32)*4;
        printf("CENTER_RGBA: %u %u %u %u; CORNER_RGBA: %u %u %u %u\n",center[0],center[1],center[2],center[3],p[0],p[1],p[2],p[3]);
        if (center[0]<254 || center[1]>1 || center[2]>1 || center[3]<254 || p[0]>1 || p[1]>1 || p[2]<254 || p[3]<254) return 10;
        puts("METAL_COMPUTE_AND_RENDER_PASS");
    }
    return 0;
}
