#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#import <os/lock.h>

static IMP original_next_drawable;
static id<CAMetalDrawable> last_presented_drawable;
static os_unfair_lock presented_drawable_lock = OS_UNFAIR_LOCK_INIT;
static id<MTLCommandQueue> capture_queue;
static BOOL capture_started;
static uint64_t observed_drawable_id;

enum {
    PixelBytes = 4,
    RowAlignment = 256,
};

static id next_drawable(CAMetalLayer *layer, SEL selector) {
    layer.framebufferOnly = NO;
    id<CAMetalDrawable> drawable = ((id (*)(id, SEL))original_next_drawable)(layer, selector);
    if (drawable) {
        [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
            if (presented.presentedTime <= 0) {
                return;
            }

            os_unfair_lock_lock(&presented_drawable_lock);
            if (!last_presented_drawable || presented.presentedTime >= last_presented_drawable.presentedTime) {
                last_presented_drawable = (id<CAMetalDrawable>)presented;
            }
            os_unfair_lock_unlock(&presented_drawable_lock);
        }];
    }

    return drawable;
}

static void write_capture(id<MTLBuffer> buffer, id<CAMetalDrawable> drawable, NSUInteger pitch) {
    const char *destination = getenv("TELAR_HISTORY_CAPTURE");
    if (destination == NULL) {
        abort();
    }

    const NSUInteger width = drawable.texture.width;
    const NSUInteger height = drawable.texture.height;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(buffer.contents, width, height, 8, pitch, space,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:image];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    const BOOL saved = [png writeToFile:@(destination) atomically:YES];
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    if (!saved) {
        abort();
    }

    NSDictionary *record = @{
        @"width": @(width),
        @"height": @(height),
        @"presented_time": @(drawable.presentedTime),
        @"drawable_id": @(drawable.drawableID),
        @"pixel_format": @(drawable.texture.pixelFormat),
        @"endpoint": @"Retained drawable after its presentation callback; separate readback submission",
    };
    NSData *metadata = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:nil];
    if (![metadata writeToFile:[@(destination) stringByAppendingString:@".json"] atomically:YES]) {
        abort();
    }
}

static void record_observation(id<CAMetalDrawable> drawable, NSDictionary *state) {
    if (observed_drawable_id == drawable.drawableID) {
        return;
    }

    observed_drawable_id = drawable.drawableID;
    NSDictionary *record = @{
        @"drawable_id": @(drawable.drawableID),
        @"presented_time": @(drawable.presentedTime),
        @"drawable_pixels": @[@(drawable.texture.width), @(drawable.texture.height)],
        @"native_pixels": state[@"view_pixels"] ?: @[],
        @"last_input_time": state[@"last_input_time"] ?: @0,
        @"app_active": state[@"app_active"] ?: @NO,
        @"window_key": state[@"window_key"] ?: @NO,
    };
    const char *destination = getenv("TELAR_HISTORY_CAPTURE");
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:nil];
    if (destination == NULL || ![data writeToFile:[@(destination) stringByAppendingString:@".observation.json"] atomically:YES]) {
        abort();
    }
}

static void capture_presented_frame(void) {
    const char *trigger = getenv("TELAR_HISTORY_CAPTURE_TRIGGER");
    if (capture_started || trigger == NULL || ![NSFileManager.defaultManager fileExistsAtPath:@(trigger)]) {
        return;
    }

    os_unfair_lock_lock(&presented_drawable_lock);
    id<CAMetalDrawable> drawable = last_presented_drawable;
    os_unfair_lock_unlock(&presented_drawable_lock);
    if (!drawable) {
        return;
    }

    id<MTLTexture> texture = drawable.texture;
    const char *state_path = getenv("TELAR_HISTORY_CAPTURE_STATE");
    if (state_path != NULL) {
        NSData *data = [NSData dataWithContentsOfFile:@(state_path)];
        NSDictionary *state = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        record_observation(drawable, state);
        NSArray *size = state[@"view_pixels"];
        if (size.count != 2 || texture.width != [size[0] unsignedIntegerValue] || texture.height != [size[1] unsignedIntegerValue]) {
            return;
        }
        if (drawable.presentedTime < [state[@"last_input_time"] doubleValue]) {
            return;
        }
    }

    capture_started = YES;
    if (texture.pixelFormat != MTLPixelFormatBGRA8Unorm && texture.pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB) {
        abort();
    }

    const NSUInteger pitch = ((texture.width * PixelBytes + RowAlignment - 1) / RowAlignment) * RowAlignment;
    capture_queue = [texture.device newCommandQueue];
    id<MTLBuffer> pixels = [texture.device newBufferWithLength:pitch * texture.height options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command = [capture_queue commandBuffer];
    id<MTLBlitCommandEncoder> copy = [command blitCommandEncoder];
    if (!pixels || !command || !copy) {
        abort();
    }

    [copy copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
        sourceSize:MTLSizeMake(texture.width, texture.height, 1) toBuffer:pixels destinationOffset:0
        destinationBytesPerRow:pitch destinationBytesPerImage:pitch * texture.height];
    [copy endEncoding];
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        if (completed.status != MTLCommandBufferStatusCompleted) {
            abort();
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            write_capture(pixels, drawable, pitch);
        });
    }];
    [command commit];
}

__attribute__((constructor)) static void install(void) {
    if (getenv("TELAR_HISTORY_CAPTURE") == NULL) {
        return;
    }

    Method next = class_getInstanceMethod(CAMetalLayer.class, @selector(nextDrawable));
    if (next == NULL) {
        abort();
    }

    original_next_drawable = method_setImplementation(next, (IMP)next_drawable);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:.05 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            capture_presented_frame();
        }];
    });
}
