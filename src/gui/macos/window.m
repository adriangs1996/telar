#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <string.h>

#include "../native/telar_gui.h"

// One instanced draw: six vertices per quad, quads read from buffer 0.
static NSString *const shader_source = @""
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct Quad { float4 rect; float4 uv; float4 color; };\n"
    "struct Vertex { float4 position [[position]]; float2 uv; float4 color; };\n"
    "vertex Vertex quad_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],\n"
    "                          constant Quad *quads [[buffer(0)]],\n"
    "                          constant float2 &viewport [[buffer(1)]]) {\n"
    "    constant Quad &q = quads[iid];\n"
    "    float2 corner = float2(vid == 1 || vid == 2 || vid == 4 ? 1.0 : 0.0,\n"
    "                           vid == 2 || vid == 4 || vid == 5 ? 1.0 : 0.0);\n"
    "    float2 pixel = q.rect.xy + corner * q.rect.zw;\n"
    "    Vertex out;\n"
    "    out.position = float4(pixel.x / viewport.x * 2.0 - 1.0, 1.0 - pixel.y / viewport.y * 2.0, 0.0, 1.0);\n"
    "    out.uv = q.uv.xy + corner * (q.uv.zw - q.uv.xy);\n"
    "    out.color = q.color;\n"
    "    return out;\n"
    "}\n"
    "fragment float4 quad_fragment(Vertex in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {\n"
    "    constexpr sampler nearest(filter::nearest);\n"
    "    float coverage = atlas.sample(nearest, in.uv).r;\n"
    "    return float4(in.color.rgb, in.color.a * coverage);\n"
    "}\n";

@interface TelarView : NSView <NSWindowDelegate>
@end

@implementation TelarView {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> pipeline;
    id<MTLTexture> atlas;
    id<MTLBuffer> quads;
    uint32_t atlas_version;
    void *context;
    telar_gui_render_fn render;
}

- (instancetype)initWithFrame:(NSRect)frame context:(void *)render_context render:(telar_gui_render_fn)render_fn {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;
    context = render_context;
    render = render_fn;
    device = MTLCreateSystemDefaultDevice();
    if (device == nil) return nil;
    queue = [device newCommandQueue];
    if (![self buildPipeline]) return nil;
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    return self;
}

- (BOOL)buildPipeline {
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:shader_source options:nil error:&error];
    if (library == nil) {
        NSLog(@"telar-gui: shader compilation failed: %@", error);
        return NO;
    }
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"quad_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"quad_fragment"];
    MTLRenderPipelineColorAttachmentDescriptor *color = descriptor.colorAttachments[0];
    color.pixelFormat = MTLPixelFormatBGRA8Unorm;
    color.blendingEnabled = YES;
    color.rgbBlendOperation = MTLBlendOperationAdd;
    color.alphaBlendOperation = MTLBlendOperationAdd;
    color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    color.sourceAlphaBlendFactor = MTLBlendFactorOne;
    color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (pipeline == nil) {
        NSLog(@"telar-gui: pipeline creation failed: %@", error);
        return NO;
    }
    return YES;
}

- (CALayer *)makeBackingLayer {
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    return layer;
}

- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer { [self draw]; }

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self resizeDrawable];
    [self draw];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self resizeDrawable];
    [self draw];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self resizeDrawable];
    [self draw];
}

- (void)resizeDrawable {
    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    CGFloat scale = self.window != nil ? self.window.backingScaleFactor : 1.0;
    layer.contentsScale = scale;
    NSSize size = self.bounds.size;
    layer.drawableSize = CGSizeMake(size.width * scale, size.height * scale);
}

- (void)uploadAtlas:(const telar_gui_frame *)frame {
    if (frame->atlas == NULL || frame->atlas_side == 0) return;
    if (atlas == nil || atlas.width != frame->atlas_side) {
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                         width:frame->atlas_side
                                        height:frame->atlas_side
                                     mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        atlas = [device newTextureWithDescriptor:descriptor];
        atlas_version = 0;
    }
    if (atlas_version == frame->atlas_version) return;
    [atlas replaceRegion:MTLRegionMake2D(0, 0, frame->atlas_side, frame->atlas_side)
             mipmapLevel:0
               withBytes:frame->atlas
             bytesPerRow:frame->atlas_side];
    atlas_version = frame->atlas_version;
}

- (void)draw {
    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    if (layer == nil || self.window == nil) return;
    CGSize size = layer.drawableSize;
    if (size.width < 1 || size.height < 1) return;

    telar_gui_viewport viewport = {(uint32_t)size.width, (uint32_t)size.height, (float)layer.contentsScale};
    telar_gui_frame frame;
    memset(&frame, 0, sizeof frame);
    render(context, viewport, &frame);
    [self uploadAtlas:&frame];

    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (drawable == nil) return;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor =
        MTLClearColorMake(frame.background[0], frame.background[1], frame.background[2], frame.background[3]);

    id<MTLCommandBuffer> commands = [queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
    if (frame.quad_count > 0 && frame.quads != NULL && atlas != nil) {
        NSUInteger bytes = frame.quad_count * sizeof(telar_gui_quad);
        if (quads == nil || quads.length < bytes) {
            quads = [device newBufferWithLength:MAX(bytes, (NSUInteger)4096) options:MTLResourceStorageModeShared];
        }
        memcpy(quads.contents, frame.quads, bytes);
        float viewport_size[2] = {(float)size.width, (float)size.height};
        [encoder setRenderPipelineState:pipeline];
        [encoder setVertexBuffer:quads offset:0 atIndex:0];
        [encoder setVertexBytes:viewport_size length:sizeof viewport_size atIndex:1];
        [encoder setFragmentTexture:atlas atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                    vertexStart:0
                    vertexCount:6
                  instanceCount:frame.quad_count];
    }
    [encoder endEncoding];
    [commands presentDrawable:drawable];
    [commands commit];
}

- (void)windowWillClose:(NSNotification *)notification {
    [NSApp stop:nil];
    // `stop:` takes effect once the run loop sees an event.
    NSEvent *wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                       location:NSZeroPoint
                                  modifierFlags:0
                                      timestamp:0
                                   windowNumber:0
                                        context:nil
                                        subtype:0
                                          data1:0
                                          data2:0];
    [NSApp postEvent:wake atStart:YES];
}
@end

int telar_gui_run(const char *title, void *context, telar_gui_render_fn render) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 800, 480)
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                        backing:NSBackingStoreBuffered
                          defer:NO];
        window.title = [NSString stringWithUTF8String:title];
        window.minSize = NSMakeSize(320, 200);
        window.releasedWhenClosed = NO;
        TelarView *view = [[TelarView alloc] initWithFrame:window.contentView.bounds context:context render:render];
        if (view == nil) return -1;
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        window.contentView = view;
        window.delegate = view;
        [window center];
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        [NSApp run];
        window.delegate = nil;
        [window close];
        return 0;
    }
}
