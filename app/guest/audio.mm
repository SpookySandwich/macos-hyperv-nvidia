#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#include <atomic>
#include <algorithm>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <thread>
#include <unistd.h>
#include <vector>
#ifdef AUDIO_GUI
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <poll.h>
#endif

constexpr size_t capacity=48000*2/20; // at most 50 ms of queued stereo audio
float ring[capacity];
std::atomic<size_t> head{0},tail{0};
std::atomic<bool> running{true};
AudioStreamBasicDescription format{};
int sinkFd=STDOUT_FILENO;
void stop(int){running=false;}
OSStatus capture(AudioObjectID,const AudioTimeStamp*,const AudioBufferList *input,const AudioTimeStamp*,AudioBufferList*,const AudioTimeStamp*,void*){
    if(!input || !input->mNumberBuffers) return noErr;
    bool planar=(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved)!=0;
    size_t frames=input->mBuffers[0].mDataByteSize/format.mBytesPerFrame;
    size_t write=head.load(std::memory_order_relaxed),read=tail.load(std::memory_order_acquire);
    for(size_t frame=0;frame<frames;frame++){
        if((write+2-read)>capacity) break; // bounded queue; never block Core Audio
        for(unsigned channel=0;channel<2;channel++){
            unsigned buffer=planar?std::min(channel,input->mNumberBuffers-1):0;
            const AudioBuffer &data=input->mBuffers[buffer];
            size_t offset=planar?frame:frame*data.mNumberChannels+std::min(channel,data.mNumberChannels-1);
            float value=0;
            if(data.mData) value=format.mBitsPerChannel==32?static_cast<const float*>(data.mData)[offset]:static_cast<float>(static_cast<const double*>(data.mData)[offset]);
            ring[write++%capacity]=value;
        }
    }
    head.store(write,std::memory_order_release);
    return noErr;
}
int streamMain(int argc,char **argv){
    running=true;head=0;tail=0;
    signal(SIGPIPE,stop);signal(SIGTERM,stop);signal(SIGINT,stop);
    AudioObjectPropertyAddress address{kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    UInt32 bytes=0;
    if(AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&address,0,nullptr,&bytes)) return 1;
    std::vector<AudioObjectID> devices(bytes/sizeof(AudioObjectID));
    AudioObjectGetPropertyData(kAudioObjectSystemObject,&address,0,nullptr,&bytes,devices.data());
    AudioObjectID device=0;
    for(auto id:devices){
        CFStringRef name=nullptr;UInt32 size=sizeof(name);
        address.mSelector=kAudioObjectPropertyName;
        if(!AudioObjectGetPropertyData(id,&address,0,nullptr,&size,&name)){
            char text[256]{};CFStringGetCString(name,text,sizeof(text),kCFStringEncodingUTF8);CFRelease(name);
            if(argc>1 && !strcmp(argv[1],"--list")) printf("%u %s\n",id,text);
            if(!strcmp(text,"BlackHole 2ch")) device=id;
        }
    }
    if(argc>1 && !strcmp(argv[1],"--list")) return 0;
    if(!device){fprintf(stderr,"BlackHole 2ch is unavailable\n");return 2;}
    if(argc>1 && !strcmp(argv[1],"--set-default")){
        for(auto selector:{kAudioHardwarePropertyDefaultOutputDevice,kAudioHardwarePropertyDefaultSystemOutputDevice}){
            address={selector,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
            OSStatus status=AudioObjectSetPropertyData(kAudioObjectSystemObject,&address,0,nullptr,sizeof(device),&device);
            if(status){fprintf(stderr,"Default output error %d\n",status);return 3;}
        }
        printf("Default output: BlackHole 2ch\n");return 0;
    }
    Float64 rate=48000;
    address={kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    OSStatus status=AudioObjectSetPropertyData(device,&address,0,nullptr,sizeof(rate),&rate);
    if(status){fprintf(stderr,"Sample-rate error %d\n",status);return 4;}
    address={kAudioDevicePropertyStreamFormat,kAudioObjectPropertyScopeInput,kAudioObjectPropertyElementMain};bytes=sizeof(format);
    status=AudioObjectGetPropertyData(device,&address,0,nullptr,&bytes,&format);
    if(status || format.mFormatID!=kAudioFormatLinearPCM || !(format.mFormatFlags & kAudioFormatFlagIsFloat) || (format.mBitsPerChannel!=32 && format.mBitsPerChannel!=64) || format.mSampleRate!=48000 || !format.mBytesPerFrame){fprintf(stderr,"Unsupported Core Audio input format\n");return 5;}
    AudioDeviceIOProcID proc=nullptr;
    status=AudioDeviceCreateIOProcID(device,capture,nullptr,&proc);
    if(!status) status=AudioDeviceStart(device,proc);
    if(status){fprintf(stderr,"Core Audio capture error %d\n",status);return 6;}
    fprintf(stderr,"AUDIO_STREAM_READY 48000 Hz stereo float32\n");
    double duration=argc>1?atof(argv[1]):0;
    auto began=std::chrono::steady_clock::now();
    float chunk[2048];
    while(running){
        size_t read=tail.load(std::memory_order_relaxed),write=head.load(std::memory_order_acquire);
        size_t amount=std::min<size_t>(write-read,2048);
        if(amount){
            for(size_t n=0;n<amount;n++) chunk[n]=ring[(read+n)%capacity];
            tail.store(read+amount,std::memory_order_release);
            size_t length=amount*sizeof(float),sent=0;
            while(sent<length && running){ssize_t result=::write(sinkFd,reinterpret_cast<char*>(chunk)+sent,length-sent);if(result<=0){running=false;break;}sent+=result;}
        }else{std::this_thread::sleep_for(std::chrono::milliseconds(3));}
        if(duration>0 && std::chrono::duration<double>(std::chrono::steady_clock::now()-began).count()>=duration) break;
    }
    AudioDeviceStop(device,proc);AudioDeviceDestroyIOProcID(device,proc);
    return 0;
}
#ifdef AUDIO_GUI
@interface AudioBridgeDelegate : NSObject <NSApplicationDelegate>
@end
@implementation AudioBridgeDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted){
        if(!granted){NSLog(@"Audio forwarding needs permission for the BlackHole virtual input.");dispatch_async(dispatch_get_main_queue(),^{[NSApp terminate:nil];});return;}
        std::thread([]{
            NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/MacHyperVAudio.sock"];
            int server=socket(AF_UNIX,SOCK_STREAM,0);
            sockaddr_un address{};address.sun_family=AF_UNIX;
            strlcpy(address.sun_path,path.fileSystemRepresentation,sizeof(address.sun_path));
            unlink(address.sun_path);
            if(bind(server,reinterpret_cast<sockaddr*>(&address),sizeof(address)) || listen(server,1)){close(server);return;}
            chmod(address.sun_path,0600);
            for(;;){
                pollfd ready{server,POLLIN,0};
                if(poll(&ready,1,60000)<=0) break;
                int client=accept(server,nullptr,nullptr);
                if(client<0) break;
                sinkFd=client;char name[]="audio-bridge";char *args[]={name};
                const char magic[8]={'M','A','C','A','U','D','I','O'};
                const uint32_t spec[4]={1,48000,2,32};
                if(write(client,magic,sizeof(magic))!=sizeof(magic) || write(client,spec,sizeof(spec))!=sizeof(spec)){close(client);continue;}
                streamMain(1,args);close(client);
            }
            close(server);unlink(address.sun_path);
            dispatch_async(dispatch_get_main_queue(),^{[NSApp terminate:nil];});
        }).detach();
    }];
}
@end
int main(int argc,char **argv){
    if(argc==2 && !strcmp(argv[1],"--version")){puts("2.0");return 0;}
    @autoreleasepool{NSApplication *app=[NSApplication sharedApplication];[app setActivationPolicy:NSApplicationActivationPolicyAccessory];AudioBridgeDelegate *delegate=[AudioBridgeDelegate new];app.delegate=delegate;[app run];}return 0;
}
#else
int main(int argc,char **argv){return streamMain(argc,argv);}
#endif
