// Standalone presentation diagnostic; zero timestamps are observations, never latency endpoints.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { ControlFramesPerPhase = 20, ControlFrameCount = 2 * ControlFramesPerPhase + 2, ControlPixelBufferBytes = 256 };
static const double ControlFrameDelaySeconds = .06;
static const double ControlIdleSeconds = 5;
static const double ControlResumeIsolationSeconds = 2;
static const double ControlStartupSeconds = 1;
static const double ControlDrainSeconds = 1;
static const double ControlTimeoutSeconds = 18;
static const double ControlIdleRedrawSeconds = 2;
static const double ControlWindowWidth = 800;
static const double ControlWindowHeight = 500;
static NSWindow *window;
static CAMetalLayer *layer;
static id<MTLCommandQueue> queue;
static unsigned submitted, completed, presented;
static BOOL commandPresentation;
static unsigned color;
static BOOL readback;

@interface ControlView : NSView
@end
@implementation ControlView
- (CALayer *)makeBackingLayer { return [CAMetalLayer layer]; }
@end

static void draw(const char *phase, BOOL change) {
    if (change) {
        color ^= 1;
    }

    const unsigned index = submitted++;
    const unsigned value = color;
    const double began = CACurrentMediaTime();
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) {
        fprintf(stderr, "nil drawable\n");
        exit(2);
    }

    const NSUInteger drawableID = drawable.drawableID;
    id<MTLCommandBuffer> buffer = [queue commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = value ? MTLClearColorMake(1, 0, 0, 1) : MTLClearColorMake(0, 0, 1, 1);
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder endEncoding];

    id<MTLBuffer> pixel = nil;
    if (readback) {
        pixel = [layer.device newBufferWithLength:ControlPixelBufferBytes options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
        [blit copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
              sourceSize:MTLSizeMake(1,1,1) toBuffer:pixel destinationOffset:0 destinationBytesPerRow:ControlPixelBufferBytes destinationBytesPerImage:ControlPixelBufferBytes];
        [blit endEncoding];
    }

    if (!NSApp.isActive || !window.isKeyWindow || !(window.occlusionState & NSWindowOcclusionStateVisible)) {
        fprintf(stderr, "foreground lost before submission\n");
        exit(6);
    }

    fprintf(stdout, "acquire index=%u phase=%s drawable=%lu time=%.9f changed=%d color=%u active=%d key=%d visible=%d pool=%lu transaction=%d sync=%d size=%lux%lu\n",
        index, phase, drawableID, began, change, value, NSApp.isActive, window.isKeyWindow,
        (window.occlusionState & NSWindowOcclusionStateVisible) != 0, layer.maximumDrawableCount,
        layer.presentsWithTransaction, layer.displaySyncEnabled, drawable.texture.width, drawable.texture.height);
    [drawable addPresentedHandler:^(id<MTLDrawable> item) {
        const double stamp = item.presentedTime;
        const double now = CACurrentMediaTime();
        dispatch_async(dispatch_get_main_queue(), ^{
            ++presented;
            fprintf(stdout, "present index=%u drawable=%lu timestamp=%.9f callback=%.9f active=%d key=%d visible=%d\n", index, drawableID, stamp, now,
                NSApp.isActive, window.isKeyWindow, (window.occlusionState & NSWindowOcclusionStateVisible) != 0);
        });
    }];

    [buffer addCompletedHandler:^(id<MTLCommandBuffer> item) {
        const unsigned char *bytes = pixel.contents;
        const BOOL verified = !readback || (bytes[0] == (value ? 0 : 255) && bytes[1] == 0 && bytes[2] == (value ? 255 : 0) && bytes[3] == 255);
        const double now = CACurrentMediaTime();
        const BOOL ok = item.status == MTLCommandBufferStatusCompleted && verified;
        dispatch_async(dispatch_get_main_queue(), ^{
            ++completed;
            fprintf(stdout, "gpu index=%u drawable=%lu time=%.9f verified=%d\n", index, drawableID, now, readback ? (int)ok : -1);
            if (!ok) {
                exit(3);
            }
        });
    }];

    if (commandPresentation) {
        [buffer presentDrawable:drawable];
    } else {
        [buffer addScheduledHandler:^(id<MTLCommandBuffer> item) {
            fprintf(stdout, "request index=%u drawable=%lu time=%.9f\n", index, drawableID, CACurrentMediaTime());
            [drawable present];
        }];
    }

    [buffer commit];
}

static void after(double seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

static void resumed(unsigned index) {
    draw("resume", YES);

    if (index + 1 < ControlFramesPerPhase) {
        after(index == 0 ? ControlResumeIsolationSeconds : ControlFrameDelaySeconds, ^{ resumed(index + 1); });
    } else {
        after(ControlDrainSeconds, ^{
            fprintf(stdout, "finish submitted=%u completed=%u callbacks=%u\n", submitted, completed, presented);
            if (submitted != ControlFrameCount || completed != submitted || presented != submitted) {
                exit(4);
            }

            [NSApp terminate:nil];
        });
    }
}

static void warmup(unsigned index) {
    draw("warmup", YES);

    if (index + 1 < ControlFramesPerPhase) {
        after(ControlFrameDelaySeconds, ^{ warmup(index + 1); });
    } else {
        after(ControlIdleRedrawSeconds, ^{ draw("idle", NO); });
        after(2 * ControlIdleRedrawSeconds, ^{ draw("idle", NO); });
        after(ControlIdleSeconds, ^{ resumed(0); });
    }
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3 || (strcmp(argv[1], "scheduled") && strcmp(argv[1], "command")) || (strcmp(argv[2], "readback") && strcmp(argv[2], "no-readback"))) {
            return 1;
        }

        readback = !strcmp(argv[2], "readback");
        commandPresentation = !strcmp(argv[1], "command");
        setbuf(stdout, NULL);
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSRect rect = NSMakeRect(100, 100, ControlWindowWidth, ControlWindowHeight);
        window = [[NSWindow alloc] initWithContentRect:rect styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.title = @"Owned Metal idle diagnostic";
        window.level = NSFloatingWindowLevel;
        ControlView *view = [[ControlView alloc] initWithFrame:rect];
        view.wantsLayer = YES;
        window.contentView = view;
        layer = (CAMetalLayer *)view.layer;
        layer.device = MTLCreateSystemDefaultDevice();
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = !readback;
        layer.presentsWithTransaction = NO;
        layer.displaySyncEnabled = YES;
        queue = [layer.device newCommandQueue];
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        after(ControlStartupSeconds, ^{
            CGFloat scale = window.backingScaleFactor;
            layer.contentsScale = scale;
            layer.drawableSize = CGSizeMake(ControlWindowWidth * scale, ControlWindowHeight * scale);
            fprintf(stdout, "setup mode=%s scale=%.1f maxfps=%ld readback=%d framebuffer_only=%d\n", argv[1], scale, (long)window.screen.maximumFramesPerSecond, readback, layer.framebufferOnly);
            warmup(0);
        });
        after(ControlTimeoutSeconds, ^{
            fprintf(stderr, "control timeout\n");
            exit(5);
        });
        [NSApp run];
    }
    return 0;
}
