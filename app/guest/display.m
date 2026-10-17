#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#include <math.h>

static NSDictionary *Mode(CGDisplayModeRef mode, NSArray *table) {
    uint32_t ident=CGDisplayModeGetIODisplayModeID(mode);
    double hz=CGDisplayModeGetRefreshRate(mode);
    if (hz<1 && ident>0 && ident<=table.count) hz=[table[ident-1][@"RefreshRate"] doubleValue] ?: 60;
    return @{@"width":@(CGDisplayModeGetWidth(mode)),@"height":@(CGDisplayModeGetHeight(mode)),
             @"refreshHz":@(hz),@"modeId":@(ident)};
}
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc==2 && !strcmp(argv[1],"--version")){puts("1.0");return 0;}
    io_service_t fb=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("HyperVNVDAGraphicsFramebuffer"));
    NSArray *table=fb?CFBridgingRelease(IORegistryEntryCreateCFProperty(fb,CFSTR("SupportedResolutions"),kCFAllocatorDefault,0)):nil;
    if(fb)IOObjectRelease(fb);
    CGDirectDisplayID display=CGMainDisplayID();
    CFArrayRef modes=CGDisplayCopyAllDisplayModes(display,(__bridge CFDictionaryRef)@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes:@YES});
    if(!modes){fprintf(stderr,"No display modes available\n");return 2;}
    NSMutableArray *available=[NSMutableArray new];
    CGDisplayModeRef selected=NULL;
    double distance=1e9;
    int w=argc==4?atoi(argv[1]):0,h=argc==4?atoi(argv[2]):0;double requested=argc==4?atof(argv[3]):0;
    if(argc!=1 && (argc!=4 || w<640 || h<480 || requested<24 || requested>240)){CFRelease(modes);return 2;}
    for(CFIndex i=0;i<CFArrayGetCount(modes);i++){
        CGDisplayModeRef m=(CGDisplayModeRef)CFArrayGetValueAtIndex(modes,i);NSDictionary *entry=Mode(m,table);
        [available addObject:entry];
        double rate=[entry[@"refreshHz"] doubleValue];
        if(argc==4 && CGDisplayModeGetWidth(m)==w && CGDisplayModeGetHeight(m)==h && rate<=requested+0.5 && requested-rate<distance){selected=m;distance=requested-rate;}
    }
    if(argc==4 && !selected){fprintf(stderr,"Requested resolution has no supported display mode\n");CFRelease(modes);return 3;}
    CGError error=kCGErrorSuccess;
    CGDisplayModeRef before=CGDisplayCopyDisplayMode(display);
    if(selected && (!before || CGDisplayModeGetIODisplayModeID(before)!=CGDisplayModeGetIODisplayModeID(selected))){
        CGDisplayConfigRef config=NULL;error=CGBeginDisplayConfiguration(&config);
        if(!error)error=CGConfigureDisplayWithDisplayMode(config,display,selected,NULL);
        if(!error)error=CGCompleteDisplayConfiguration(config,kCGConfigureForSession);
        else if(config)CGCancelDisplayConfiguration(config);
    }
    if(before)CGDisplayModeRelease(before);
    CGDisplayModeRef current=CGDisplayCopyDisplayMode(display);
    NSMutableDictionary *result=[NSMutableDictionary dictionaryWithDictionary:@{@"error":@(error),@"available":available}];
    if(current){result[@"current"]=Mode(current,table);CGDisplayModeRelease(current);}
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);CFRelease(modes);
    return error?4:0;
} }
