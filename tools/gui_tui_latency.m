// Test-only common probe: one IOSurface pixel copied in the rendering command
// buffer, then verified at GPU completion. Works with CAMetalLayer and Ghostty
// 1.3 IOSurface targets. No presentation/scanout timestamps are inferred.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static IMP original_next, original_encoder, original_commit;
static char texture_key;
static FILE *probe_log;
static id<MTLCommandQueue> probe_queue;
static atomic_uint epoch;
static atomic_bool located;
static atomic_ulong marker_x, marker_y, pixel_width, pixel_height;
static BOOL pending, finished;
static int count, limit;
static double began, gpu_samples[512];
static NSString *input_class;

@interface ProbeFrame : NSObject {
@public unsigned sequence; double gpu; BOOL verified;
}
@end
@implementation ProbeFrame
@end

static void finish(int failed) {
    if (finished) return;
    finished=YES;
    FILE *f=fopen(getenv("TELAR_DISPLAY_RESULT"),"w");
    if (f) {
        fprintf(f,"{\"failed\":%d,\"viewport\":[%lu,%lu],\"marker\":[%lu,%lu],\"gpu_ms\":[",failed,pixel_width,pixel_height,marker_x,marker_y);
        for(int i=0;i<count;i++)fprintf(f,"%s%.6f",i?",":"",gpu_samples[i]);
        fprintf(f,"],\"input_class\":\"%s\"}\n",input_class.UTF8String ?: "");fclose(f);
    }
    if ([NSApp.keyWindow.contentView respondsToSelector:@selector(keyDown:)]) [NSApp.keyWindow close];
    // Ghostty can keep its app process alive after closing the only test window.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{ [NSApp terminate:nil]; });
}

static void send_key(void) {
    if(finished)return;
    if(count==limit){finish(0);return;}
    NSWindow *w=NSApp.keyWindow;
    if(!w){finish(2);return;}
    NSResponder *target=w.firstResponder;
    if(!count)input_class=NSStringFromClass(target.class);
    pending=YES;
    atomic_store(&epoch,(unsigned)count+1);
    began=CACurrentMediaTime();
    [target keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:w.windowNumber context:nil characters:@"x" charactersIgnoringModifiers:@"x" isARepeat:NO keyCode:7]];
}

static void accept_frame(ProbeFrame *frame) {
    if(!pending || frame->sequence!=(unsigned)count+1 || !frame->verified || !frame->gpu)return;
    gpu_samples[count]=(frame->gpu-began)*1000;
    if(gpu_samples[count]<0){finish(3);return;}
    pending=NO;count++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(25+((uint32_t)(count*1103515245u+12345u)>>16)%50)*NSEC_PER_MSEC),dispatch_get_main_queue(),^{send_key();});
}

static int color(const uint8_t *p) {
    if(p[2]>160 && p[1]<80 && p[0]<120)return 0;
    if(p[1]>p[2]+60 && p[1]>160 && p[0]>120)return 1;
    return -1;
}

static id encoder(id self,SEL selector,MTLRenderPassDescriptor *pass){
    id<MTLTexture> texture=pass.colorAttachments[0].texture;
    if(texture.iosurface && (texture.pixelFormat==MTLPixelFormatBGRA8Unorm || texture.pixelFormat==MTLPixelFormatBGRA8Unorm_sRGB)){
        objc_setAssociatedObject(self,&texture_key,texture,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return ((id(*)(id,SEL,id))original_encoder)(self,selector,pass);
}

static void commit(id self,SEL selector){
    id<MTLTexture> texture=objc_getAssociatedObject(self,&texture_key);
    if(texture){
        ProbeFrame *frame=[ProbeFrame new];frame->sequence=atomic_load(&epoch);
        BOOL known=atomic_load_explicit(&located,memory_order_acquire) && pixel_width==texture.width && pixel_height==texture.height;
        NSUInteger x=known?marker_x:0, y=known?marker_y:0;
        NSUInteger width=known?1:texture.width, height=known?1:texture.height;
        NSUInteger pitch=(width*4+255)&~255ul;
        id<MTLBuffer> bytes=[texture.device newBufferWithLength:pitch*height options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> blit=[(id<MTLCommandBuffer>)self blitCommandEncoder];
        [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x,y,0) sourceSize:MTLSizeMake(width,height,1) toBuffer:bytes destinationOffset:0 destinationBytesPerRow:pitch destinationBytesPerImage:pitch*height];
        [blit endEncoding];
        [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> completed){
            double done=CACurrentMediaTime();
            if(completed.status!=MTLCommandBufferStatusCompleted)return;
            if(frame->sequence && !known){dispatch_async(dispatch_get_main_queue(),^{finish(6);});return;}
            const uint8_t *p=bytes.contents;
            if(!known){
                NSUInteger sx=0,sy=0,n=0;
                for(NSUInteger row=0;row<height;row++)for(NSUInteger col=0;col<width;col++)if(color(p+row*pitch+4*col)==0){sx+=col;sy+=row;n++;}
                if(n)dispatch_async(dispatch_get_main_queue(),^{
                    marker_x=sx/n;marker_y=sy/n;pixel_width=texture.width;pixel_height=texture.height;
                    atomic_store_explicit(&located,true,memory_order_release);
                    fprintf(probe_log,"probe located %lu,%lu in %lux%lu\n",marker_x,marker_y,pixel_width,pixel_height);
                });
            }else{
                int value=color(p);
                dispatch_async(dispatch_get_main_queue(),^{frame->gpu=done;frame->verified=value==(int)(frame->sequence&1);accept_frame(frame);});
            }
        }];
    }
    ((void(*)(id,SEL))original_commit)(self,selector);
}

static id next_drawable(CAMetalLayer *self,SEL selector){
    self.framebufferOnly=NO;
    return ((id(*)(id,SEL))original_next)(self,selector);
}

__attribute__((constructor)) static void install(void){
    if(!getenv("TELAR_DISPLAY_RESULT"))return;
    // Runtime and fixture subprocesses inherit the environment; only GUI hosts instrument Metal.
    NSString *name=NSProcessInfo.processInfo.processName;
    if(![name isEqualToString:@"ghostty"] && ![NSProcessInfo.processInfo.arguments containsObject:@"gui"])return;
    probe_log=fopen([[NSString stringWithUTF8String:getenv("TELAR_DISPLAY_RESULT")] stringByAppendingString:@".log"].UTF8String,"w");
    setbuf(probe_log,NULL);
    limit=atoi(getenv("TELAR_DISPLAY_SAMPLES"));if(limit<1 || limit>512)abort();
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();probe_queue=[device newCommandQueue];
    id<MTLCommandBuffer> command=[probe_queue commandBuffer];
    original_encoder=method_setImplementation(class_getInstanceMethod([command class],@selector(renderCommandEncoderWithDescriptor:)),(IMP)encoder);
    original_commit=method_setImplementation(class_getInstanceMethod([command class],@selector(commit)),(IMP)commit);
    original_next=method_setImplementation(class_getInstanceMethod(CAMetalLayer.class,@selector(nextDrawable)),(IMP)next_drawable);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,4*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(!atomic_load(&located)){finish(4);return;}send_key();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC),dispatch_get_main_queue(),^{finish(5);});
}
