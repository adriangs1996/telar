// Test-only probe: writes the window's presented pixels to PNG files without
// the screen recording permission `screencapture` needs. Inject it with
// DYLD_INSERT_LIBRARIES; TELAR_GUI_CAPTURE_DIR names the output directory.
// Each quiet period after a frame (no newer frame for 300 ms) writes
// frame-NNN.png from the drawable Metal presented. It adds no branches to
// the application.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static IMP original_layer;
static IMP original_render;
static id<CAMetalDrawable> last_drawable;
static uint64_t frame_serial;
static unsigned capture_serial;

static CALayer *make_layer(id self, SEL command) {
    CALayer *layer = ((CALayer * (*)(id, SEL)) original_layer)(self, command);
    ((CAMetalLayer *)layer).framebufferOnly = NO;
    return layer;
}

static void write_png(id<MTLTexture> texture) {
    const char *directory = getenv("TELAR_GUI_CAPTURE_DIR");
    if (directory == NULL || texture == nil) {
        return;
    }

    NSUInteger width = texture.width, height = texture.height, row = width * 4;
    NSMutableData *pixels = [NSMutableData dataWithLength:row * height];
    [texture getBytes:pixels.mutableBytes bytesPerRow:row
           fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, row, space,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:image];
    NSString *path = [NSString stringWithFormat:@"%s/frame-%03u.png", directory, capture_serial++];
    [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
}

static BOOL render(id self, SEL command, const void *frame, id<CAMetalDrawable> drawable) {
    BOOL submitted = ((BOOL (*)(id, SEL, const void *, id<CAMetalDrawable>))original_render)(self, command, frame, drawable);
    if (!submitted) {
        return submitted;
    }

    last_drawable = drawable;
    uint64_t serial = ++frame_serial;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (serial == frame_serial) {
            write_png(last_drawable.texture);
        }
    });
    return submitted;
}

__attribute__((constructor)) static void install(void) {
    Method layer = class_getInstanceMethod(objc_getClass("TelarView"), @selector(makeBackingLayer));
    original_layer = method_setImplementation(layer, (IMP)make_layer);
    Method draw = class_getInstanceMethod(objc_getClass("TelarMetalRenderer"), @selector(renderFrame:drawable:));
    original_render = method_setImplementation(draw, (IMP)render);
}
