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
static char texture_key, readback_key;
static IMP original_encoder4, original_end4, original_commit4, original_layer;
static FILE *probe_log;
static id<MTLCommandQueue> probe_queue;
static atomic_uint epoch;
static atomic_bool located;
static atomic_ulong marker_x, marker_y, pixel_width, pixel_height;
static BOOL pending, finished;
static int count, limit;
static double began, gpu_samples[512], gpu_work_samples[512];
static NSString *input_class;

@interface ProbeFrame : NSObject {
@public unsigned sequence; double gpu, work; BOOL verified;
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
        fprintf(f,"],\"gpu_work_ms\":[");
        for(int i=0;i<count;i++)fprintf(f,"%s%.6f",i?",":"",gpu_work_samples[i]);
        fprintf(f,"],\"input_class\":\"%s\"}\n",input_class.UTF8String ?: "");fclose(f);
    }
    if ([NSApp.windows.firstObject.contentView respondsToSelector:@selector(keyDown:)]) [NSApp.windows.firstObject close];
    // Ghostty can keep its app process alive after closing the only test window.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{ [NSApp terminate:nil]; });
}

static void send_key(void) {
    if(finished)return;
    if(count==limit){finish(0);return;}
    NSWindow *w=NSApp.windows.firstObject;
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
    gpu_work_samples[count] = frame->work;
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

@interface ProbeReadback : NSObject {
@public ProbeFrame *frame;
    id<MTLTexture> texture;
    id<MTLBuffer> bytes;
    id<MTLResidencySet> residency;
    BOOL known;
    NSUInteger x, y, width, height, pitch;
}
@end
@implementation ProbeReadback
@end

static ProbeReadback *prepare_readback(id<MTLTexture> texture) {
    ProbeReadback *r = [ProbeReadback new];
    r->texture = texture;
    r->frame = [ProbeFrame new];
    r->frame->sequence = atomic_load(&epoch);
    r->known = atomic_load_explicit(&located, memory_order_acquire) &&
        pixel_width == texture.width && pixel_height == texture.height;
    r->x = r->known ? marker_x : 0;
    r->y = r->known ? marker_y : 0;
    r->width = r->known ? 1 : texture.width;
    r->height = r->known ? 1 : texture.height;
    r->pitch = (r->width * 4 + 255) & ~255ul;
    r->bytes = [texture.device newBufferWithLength:r->pitch * r->height options:MTLResourceStorageModeShared];
    return r;
}

static void verify_readback(ProbeReadback *r, double done) {
    if (r->frame->sequence && !r->known) {
        dispatch_async(dispatch_get_main_queue(), ^{ finish(6); });
        return;
    }
    const uint8_t *p = r->bytes.contents;
    if (!r->known) {
        NSUInteger sx = 0, sy = 0, n = 0;
        for (NSUInteger row = 0; row < r->height; row++) {
            for (NSUInteger col = 0; col < r->width; col++) {
                if (color(p + row * r->pitch + 4 * col) == 0) {
                    sx += col; sy += row; n++;
                }
            }
        }
        if (n) dispatch_async(dispatch_get_main_queue(), ^{
            marker_x = sx/n; marker_y = sy/n;
            pixel_width = r->texture.width; pixel_height = r->texture.height;
            atomic_store_explicit(&located, true, memory_order_release);
            fprintf(probe_log, "probe located %lu,%lu in %lux%lu\n", marker_x, marker_y, pixel_width, pixel_height);
        });
    } else {
        int value = color(p);
        dispatch_async(dispatch_get_main_queue(), ^{
            r->frame->gpu = done;
            r->frame->verified = value == (int)(r->frame->sequence & 1);
            accept_frame(r->frame);
        });
    }
}

// Both encoders expose this copy selector. Readback stays in the measured submission.
static void copy_pixel(id blit, ProbeReadback *r) {
    [blit copyFromTexture:r->texture sourceSlice:0 sourceLevel:0
        sourceOrigin:MTLOriginMake(r->x, r->y, 0) sourceSize:MTLSizeMake(r->width, r->height, 1)
        toBuffer:r->bytes destinationOffset:0 destinationBytesPerRow:r->pitch
        destinationBytesPerImage:r->pitch * r->height];
    [blit endEncoding];
}

static void commit(id self, SEL selector) {
    id<MTLTexture> texture = objc_getAssociatedObject(self, &texture_key);
    if (texture) {
        ProbeReadback *r = prepare_readback(texture);
        copy_pixel([(id<MTLCommandBuffer>)self blitCommandEncoder], r);
        [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            double done = CACurrentMediaTime();
            if (completed.status == MTLCommandBufferStatusCompleted) {
                r->frame->work = (completed.GPUEndTime - completed.GPUStartTime) * 1000;
                verify_readback(r, done);
            }
        }];
    }
    ((void(*)(id,SEL))original_commit)(self,selector);
}

static id encoder4(id self, SEL selector, MTL4RenderPassDescriptor *pass) {
    objc_setAssociatedObject(self, &texture_key, pass.colorAttachments[0].texture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return ((id(*)(id,SEL,id))original_encoder4)(self,selector,pass);
}

static void end4(id<MTL4CommandBuffer> self, SEL selector) {
    id<MTLTexture> texture = objc_getAssociatedObject(self, &texture_key);
    if (texture) {
        ProbeReadback *r = prepare_readback(texture);
        MTLResidencySetDescriptor *desc = [MTLResidencySetDescriptor new];
        desc.initialCapacity = 2;
        r->residency = [texture.device newResidencySetWithDescriptor:desc error:nil];
        [r->residency addAllocation:texture];
        [r->residency addAllocation:r->bytes];
        [r->residency commit];
        [self useResidencySet:r->residency];
        id<MTL4ComputeCommandEncoder> blit = [self computeCommandEncoder];
        [blit barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:0];
        copy_pixel(blit, r);
        objc_setAssociatedObject(self, &readback_key, r, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ((void(*)(id,SEL))original_end4)(self,selector);
}

static void commit4(id self, SEL selector, const id<MTL4CommandBuffer> *buffers, NSUInteger count, MTL4CommitOptions *options) {
    for (NSUInteger i = 0; i < count; i++) {
        ProbeReadback *r = objc_getAssociatedObject(buffers[i], &readback_key);
        if (r) [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
            double done = CACurrentMediaTime();
            if (!feedback.error) {
                r->frame->work = (feedback.GPUEndTime - feedback.GPUStartTime) * 1000;
                verify_readback(r, done);
            }
        }];
    }
    ((void(*)(id,SEL,const id<MTL4CommandBuffer> *,NSUInteger,id))original_commit4)(self,selector,buffers,count,options);
}

static id backing_layer(id self, SEL selector) {
    CAMetalLayer *layer = ((id(*)(id,SEL))original_layer)(self,selector);
    layer.framebufferOnly = NO;
    return layer;
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
    if (@available(macOS 26.0, *)) {
        if ([device supportsFamily:MTLGPUFamilyMetal4]) {
            id<MTL4CommandBuffer> c4 = [device newCommandBuffer];
            id<MTL4CommandQueue> q4 = [device newMTL4CommandQueue];
            original_encoder4 = method_setImplementation(class_getInstanceMethod([c4 class], @selector(renderCommandEncoderWithDescriptor:)), (IMP)encoder4);
            original_end4 = method_setImplementation(class_getInstanceMethod([c4 class], @selector(endCommandBuffer)), (IMP)end4);
            original_commit4 = method_setImplementation(class_getInstanceMethod([q4 class], @selector(commit:count:options:)), (IMP)commit4);
            Class view = objc_getClass("TelarView");
            if (view) original_layer = method_setImplementation(class_getInstanceMethod(view, @selector(makeBackingLayer)), (IMP)backing_layer);
        }
    }
    original_next=method_setImplementation(class_getInstanceMethod(CAMetalLayer.class,@selector(nextDrawable)),(IMP)next_drawable);
    const char *viewport = getenv("TELAR_DISPLAY_VIEWPORT");
    if (viewport) {
        unsigned width, height;
        if (sscanf(viewport, "%u,%u", &width, &height) != 2) abort();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSView *view = NSApp.windows.firstObject.contentView;
            CGFloat scale = view.window.backingScaleFactor;
            view.autoresizingMask = NSViewNotSizable;
            [view setFrameSize:NSMakeSize(width / scale, height / scale)];
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,4*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(!atomic_load(&located)){finish(4);return;}send_key();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC),dispatch_get_main_queue(),^{finish(5);});
}
