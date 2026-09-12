#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalDisplayLink.h>
#import <QuartzCore/CAMetalLayer.h>

#include <string.h>

#include "../native/telar_gui.h"

// One instanced draw: six vertices per quad, quads read from buffer 0.
static NSString *const shader_source =
    @""
     "#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct Quad { float4 rect; float4 uv; float4 color; };\n"
     "struct Vertex { float4 position [[position]]; float2 uv; float4 color; "
     "};\n"
     "vertex Vertex quad_vertex(uint vid [[vertex_id]], uint iid "
     "[[instance_id]],\n"
     "                          constant Quad *quads [[buffer(0)]],\n"
     "                          constant float2 &viewport [[buffer(1)]]) {\n"
     "    constant Quad &q = quads[iid];\n"
     "    float2 corner = float2(vid == 1 || vid == 2 || vid == 4 ? 1.0 : "
     "0.0,\n"
     "                           vid == 2 || vid == 4 || vid == 5 ? 1.0 : "
     "0.0);\n"
     "    float2 pixel = q.rect.xy + corner * q.rect.zw;\n"
     "    Vertex out;\n"
     "    out.position = float4(pixel.x / viewport.x * 2.0 - 1.0, 1.0 - "
     "pixel.y / viewport.y * 2.0, 0.0, 1.0);\n"
     "    out.uv = q.uv.xy + corner * (q.uv.zw - q.uv.xy);\n"
     "    out.color = q.color;\n"
     "    return out;\n"
     "}\n"
     "fragment float4 quad_fragment(Vertex in [[stage_in]], texture2d<float> "
     "atlas [[texture(0)]]) {\n"
     "    constexpr sampler nearest(filter::nearest);\n"
     "    float coverage = atlas.sample(nearest, in.uv).r;\n"
     "    return float4(in.color.rgb, in.color.a * coverage);\n"
     "}\n";

@interface TelarView
    : NSView <NSWindowDelegate, NSTextInputClient, CAMetalDisplayLinkDelegate>
@end

@implementation TelarView {
  id<MTLDevice> device;
  id<MTLCommandQueue> queue;
  id<MTLRenderPipelineState> pipeline;
  id<MTLTexture> atlas;
  id<MTLBuffer> quads;
  uint32_t atlas_version;
  uint32_t text_phase;
  void *context;
  telar_gui_callbacks callbacks;
  dispatch_source_t wake_source;
  id<MTLCommandBuffer> active_commands;
  NSMutableAttributedString *marked;
  BOOL in_flight, dirty, scheduled, closed;
  CFTimeInterval last_draw;
}

- (instancetype)initWithFrame:(NSRect)frame
                      context:(void *)render_context
                    callbacks:(const telar_gui_callbacks *)callback_table {
  self = [super initWithFrame:frame];

  if (self == nil) {
    return nil;
  }
  context = render_context;
  callbacks = *callback_table;
  marked = [NSMutableAttributedString new];
  text_phase = 1;
  device = MTLCreateSystemDefaultDevice();
  if (device == nil)
    return nil;
  queue = [device newCommandQueue];
  if (![self buildPipeline])
    return nil;
  self.wantsLayer = YES;
  self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
  return self;
}

- (BOOL)buildPipeline {
  NSError *error = nil;
  id<MTLLibrary> library = [device newLibraryWithSource:shader_source
                                                options:nil
                                                  error:&error];
  if (library == nil) {
    NSLog(@"telar-gui: shader compilation failed: %@", error);
    return NO;
  }

  MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
  descriptor.vertexFunction = [library newFunctionWithName:@"quad_vertex"];
  descriptor.fragmentFunction = [library newFunctionWithName:@"quad_fragment"];
  MTLRenderPipelineColorAttachmentDescriptor *color =
      descriptor.colorAttachments[0];
  color.pixelFormat = MTLPixelFormatBGRA8Unorm;
  color.blendingEnabled = YES;
  color.rgbBlendOperation = MTLBlendOperationAdd;
  color.alphaBlendOperation = MTLBlendOperationAdd;
  color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  color.sourceAlphaBlendFactor = MTLBlendFactorOne;
  color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  pipeline = [device newRenderPipelineStateWithDescriptor:descriptor
                                                    error:&error];
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
  layer.displaySyncEnabled = YES;
  return layer;
}

- (BOOL)wantsUpdateLayer {
  return YES;
}
- (void)updateLayer {
  [self requestDraw];
}

- (void)setFrameSize:(NSSize)size {
  [super setFrameSize:size];
  [self resizeDrawable];
  [self requestDraw];
}

- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];
  [self resizeDrawable];
  [self requestDraw];
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [self resizeDrawable];
  [self requestDraw];
}

- (void)resizeDrawable {
  CAMetalLayer *layer = (CAMetalLayer *)self.layer;
  CGFloat scale = self.window != nil ? self.window.backingScaleFactor : 1.0;
  layer.contentsScale = scale;
  NSSize size = self.bounds.size;
  layer.drawableSize = CGSizeMake(size.width * scale, size.height * scale);
}

- (void)uploadAtlas:(const telar_gui_frame *)frame {
  if (frame->atlas == NULL || frame->atlas_side == 0)
    return;
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
  if (atlas_version == frame->atlas_version)
    return;
  [atlas
      replaceRegion:MTLRegionMake2D(0, 0, frame->atlas_side, frame->atlas_side)
        mipmapLevel:0
          withBytes:frame->atlas
        bytesPerRow:frame->atlas_side];
  atlas_version = frame->atlas_version;
}

- (void)startWakeSource {
  wake_source =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, callbacks.wake_fd, 0,
                             dispatch_get_main_queue());
  __weak TelarView *weak = self;
  dispatch_source_set_event_handler(wake_source, ^{
    TelarView *view = weak;
    if (view == nil || view->closed)
      return;
    telar_gui_drain(view->callbacks.wake_fd);
    int result = view->callbacks.pump(view->context);
    if (result < 0)
      [view.window close];
    else if (result > 0)
      [view requestDraw];
  });
  dispatch_resume(wake_source);
}

- (void)requestDraw {
  if (closed) {
    return;
  }

  dirty = YES;

  if (scheduled || in_flight) {
    return;
  }

  scheduled = YES;
  double delay = MAX(0.0, last_draw + 1.0 / 60.0 - CACurrentMediaTime());
  __weak TelarView *weak = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        TelarView *view = weak;

        if (view == nil || view->closed) {
          return;
        }

        view->scheduled = NO;
        [view draw];
      });
}

- (void)draw {
  CAMetalLayer *layer = (CAMetalLayer *)self.layer;
  if (layer == nil || self.window == nil)
    return;
  CGSize size = layer.drawableSize;
  if (size.width < 1 || size.height < 1)
    return;

  telar_gui_viewport viewport = {(uint32_t)size.width, (uint32_t)size.height,
                                 (float)layer.contentsScale};
  telar_gui_frame frame;
  memset(&frame, 0, sizeof frame);
  if (in_flight || closed)
    return;
  dirty = NO;
  last_draw = CACurrentMediaTime();
  callbacks.render(context, viewport, &frame);
  [self uploadAtlas:&frame];

  id<CAMetalDrawable> drawable = [layer nextDrawable];
  if (drawable == nil) {
    callbacks.complete(context, frame.token, 0);
    if (self.window.occlusionState & NSWindowOcclusionStateVisible)
      [self requestDraw];
    return;
  }
  MTLRenderPassDescriptor *pass =
      [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = drawable.texture;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  pass.colorAttachments[0].clearColor =
      MTLClearColorMake(frame.background[0], frame.background[1],
                        frame.background[2], frame.background[3]);

  id<MTLCommandBuffer> commands = [queue commandBuffer];
  id<MTLRenderCommandEncoder> encoder =
      [commands renderCommandEncoderWithDescriptor:pass];
  if (frame.quad_count > 0 && frame.quads != NULL && atlas != nil) {
    NSUInteger bytes = frame.quad_count * sizeof(telar_gui_quad);
    if (quads == nil || quads.length < bytes) {
      quads = [device newBufferWithLength:MAX(bytes, (NSUInteger)4096)
                                  options:MTLResourceStorageModeShared];
    }
    memcpy(quads.contents, frame.quads, bytes);
    float viewport_size[2] = {(float)size.width, (float)size.height};
    [encoder setRenderPipelineState:pipeline];
    [encoder setVertexBuffer:quads offset:0 atIndex:0];
    [encoder setVertexBytes:viewport_size
                     length:sizeof viewport_size
                    atIndex:1];
    [encoder setFragmentTexture:atlas atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:6
              instanceCount:frame.quad_count];
  }
  [encoder endEncoding];
  [commands presentDrawable:drawable];
  in_flight = YES;
  active_commands = commands;
  uint64_t token = frame.token;
  __weak TelarView *weak = self;
  [commands addCompletedHandler:^(id<MTLCommandBuffer> completed) {
    BOOL success = completed.status == MTLCommandBufferStatusCompleted;
    dispatch_async(dispatch_get_main_queue(), ^{
      TelarView *view = weak;
      if (view == nil || view->closed)
        return;
      view->in_flight = NO;
      view->active_commands = nil;
      view->callbacks.complete(view->context, token, success);
      int result = view->callbacks.pump(view->context);
      if (result < 0)
        [view.window close];
      else if (view->dirty || result > 0)
        [view requestDraw];
    });
  }];
  [commands commit];
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (void)sendText:(NSString *)text kind:(uint32_t)kind {
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
  telar_gui_input event = {.kind = kind,
                           .phase = kind == 1 ? text_phase : 1,
                           .text = data.bytes,
                           .len = data.length};
  if (!callbacks.input(context, event))
    NSBeep();
}

- (void)paste:(id)sender {
  NSString *text =
      [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
  if (text != nil)
    [self sendText:text kind:2];
}

- (void)keyDown:(NSEvent *)event {
  text_phase = event.isARepeat ? 2 : 1;
  if ((event.modifierFlags & NSEventModifierFlagCommand) &&
      [[event.charactersIgnoringModifiers lowercaseString]
          isEqualToString:@"v"]) {
    [self paste:nil];
    return;
  }
  if (event.modifierFlags & NSEventModifierFlagCommand)
    return;
  uint32_t code = 0;
  switch (event.keyCode) {
  case 36:
  case 76:
    code = 1;
    break;
  case 48:
    code = 2;
    break;
  case 51:
    code = 3;
    break;
  case 53:
    code = 4;
    break;
  case 126:
    code = 5;
    break;
  case 125:
    code = 6;
    break;
  case 123:
    code = 7;
    break;
  case 124:
    code = 8;
    break;
  case 115:
    code = 9;
    break;
  case 119:
    code = 10;
    break;
  case 117:
    code = 11;
    break;
  case 116:
    code = 12;
    break;
  case 121:
    code = 13;
    break;
  }
  uint32_t mods = ((event.modifierFlags & NSEventModifierFlagShift) ? 1 : 0) |
                  ((event.modifierFlags & NSEventModifierFlagOption) ? 2 : 0) |
                  ((event.modifierFlags & NSEventModifierFlagControl) ? 4 : 0);
  if (code != 0) {
    telar_gui_input input = {.kind = 3,
                             .code = code,
                             .mods = mods,
                             .phase = event.isARepeat ? 2 : 1};
    if (!callbacks.input(context, input))
      NSBeep();
  } else if (mods & 4) {
    NSString *characters = event.charactersIgnoringModifiers;
    if (characters.length == 1) {
      telar_gui_input input = {.kind = 4,
                               .code = [characters characterAtIndex:0],
                               .mods = mods,
                               .phase = event.isARepeat ? 2 : 1};
      if (!callbacks.input(context, input))
        NSBeep();
    }
  } else {
    [self interpretKeyEvents:@[ event ]];
  }
}

- (void)insertText:(id)value replacementRange:(NSRange)range {
  NSString *text =
      [value isKindOfClass:NSAttributedString.class] ? [value string] : value;
  [self unmarkText];
  [self sendText:text kind:1];
}
- (void)setMarkedText:(id)value
        selectedRange:(NSRange)selection
     replacementRange:(NSRange)replacement {
  NSAttributedString *text =
      [value isKindOfClass:NSAttributedString.class]
          ? value
          : [[NSAttributedString alloc] initWithString:value];
  [marked setAttributedString:text];
}
- (void)unmarkText {
  [marked deleteCharactersInRange:NSMakeRange(0, marked.length)];
}
- (BOOL)hasMarkedText {
  return marked.length != 0;
}
- (NSRange)markedRange {
  return marked.length ? NSMakeRange(0, marked.length)
                       : NSMakeRange(NSNotFound, 0);
}
- (NSRange)selectedRange {
  return NSMakeRange(NSNotFound, 0);
}
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText {
  return @[];
}
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range
                                                actualRange:
                                                    (NSRangePointer)actual {
  return nil;
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point {
  return NSNotFound;
}
- (NSRect)firstRectForCharacterRange:(NSRange)range
                         actualRange:(NSRangePointer)actual {
  return
      [self.window convertRectToScreen:[self convertRect:NSMakeRect(0, 0, 1, 16)
                                                  toView:nil]];
}
- (void)doCommandBySelector:(SEL)selector {
}

- (void)windowWillClose:(NSNotification *)notification {
  closed = YES;
  if (wake_source != nil)
    dispatch_source_cancel(wake_source);
  if (active_commands != nil)
    [active_commands waitUntilCompleted];
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

int telar_gui_run(const char *title, void *context,
                  const telar_gui_callbacks *callbacks) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 480)
                                    styleMask:NSWindowStyleMaskTitled |
                                              NSWindowStyleMaskClosable |
                                              NSWindowStyleMaskResizable
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    window.title = [NSString stringWithUTF8String:title];
    window.minSize = NSMakeSize(320, 200);
    window.releasedWhenClosed = NO;
    TelarView *view = [[TelarView alloc] initWithFrame:window.contentView.bounds
                                               context:context
                                             callbacks:callbacks];
    if (view == nil)
      return -1;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    window.contentView = view;
    window.delegate = view;
    [view startWakeSource];
    [window makeFirstResponder:view];
    [window center];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [NSApp run];
    window.delegate = nil;
    [window close];
    return 0;
  }
}

int telar_gui_clipboard(const uint8_t *bytes, size_t len) {
  NSString *text = [[NSString alloc] initWithBytes:bytes
                                            length:len
                                          encoding:NSUTF8StringEncoding];
  if (text == nil)
    return -1;
  [NSPasteboard.generalPasteboard clearContents];
  return [NSPasteboard.generalPasteboard setString:text
                                           forType:NSPasteboardTypeString]
             ? 0
             : -1;
}
