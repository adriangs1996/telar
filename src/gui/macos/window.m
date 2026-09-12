#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CADisplayLink.h>
#import <QuartzCore/CAMetalLayer.h>

#include <string.h>

#include "../native/telar_gui.h"

static const unsigned char shader_source[] = {
#embed "../shaders/quad.metal"
};

@interface TelarView
    : NSView <NSWindowDelegate, NSTextInputClient>
@end

@implementation TelarView {
  id<MTLDevice> device;
  id<MTL4CommandQueue> queue;
  id<MTL4CommandBuffer> commands;
  id<MTL4CommandAllocator> command_allocator;
  id<MTL4ArgumentTable> arguments;
  id<MTLResidencySet> residency;
  id<MTLBuffer> viewport_buffer;
  MTL4CommitOptions *commit_options;
  MTL4RenderPassDescriptor *render_pass;
  id<CAMetalDrawable> active_drawable;
  MTL4CommitFeedbackHandler feedback_handler;
  dispatch_group_t gpu_work;
  uint64_t active_token;
  id<MTLRenderPipelineState> pipeline;
  id<MTLTexture> atlas;
  id<MTLBuffer> quads;
  uint32_t atlas_version;
  uint32_t text_phase;
  void *context;
  telar_gui_callbacks callbacks;
  dispatch_source_t wake_source;
  NSMutableAttributedString *marked;
  BOOL in_flight, dirty, closed;
  CADisplayLink *display_link;
  CFTimeInterval next_draw;
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

  if (device == nil) {
    return nil;
  }

  if (![device supportsFamily:MTLGPUFamilyMetal4]) {
    NSLog(@"telar-gui: Metal 4 requires a supported Apple GPU");
    return nil;
  }

  if (![self buildSubmission]) {
    return nil;
  }

  if (![self buildPipeline]) {
    return nil;
  }

  self.wantsLayer = YES;
  self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;

  display_link = [self displayLinkWithTarget:self selector:@selector(displayDidRefresh:)];
  display_link.paused = YES;
  display_link.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);

  [display_link addToRunLoop:[NSRunLoop mainRunLoop]
                     forMode:NSRunLoopCommonModes];

  return self;
}

// Initialize the single reusable submission slot, e.g. [self buildSubmission].
- (BOOL)buildSubmission {
  queue = [device newMTL4CommandQueue];
  commands = [device newCommandBuffer];
  command_allocator = [device newCommandAllocator];
  MTL4ArgumentTableDescriptor *bindings = [MTL4ArgumentTableDescriptor new];
  bindings.maxBufferBindCount = 2;
  bindings.maxTextureBindCount = 1;
  NSError *error = nil;
  arguments = [device newArgumentTableWithDescriptor:bindings error:&error];
  MTLResidencySetDescriptor *resident = [MTLResidencySetDescriptor new];
  resident.initialCapacity = 4;
  residency = [device newResidencySetWithDescriptor:resident error:&error];
  viewport_buffer = [device newBufferWithLength:sizeof(float) * 2 options:MTLResourceStorageModeShared];

  if (queue == nil || commands == nil || command_allocator == nil ||
      arguments == nil || residency == nil || viewport_buffer == nil) {
    NSLog(@"telar-gui: Metal 4 resource initialization failed: %@", error);
    return NO;
  }

  [queue addResidencySet:residency];
  gpu_work = dispatch_group_create();
  commit_options = [MTL4CommitOptions new];
  render_pass = [MTL4RenderPassDescriptor new];
  __weak TelarView *weak = self;
  dispatch_group_t completion_group = gpu_work;
  feedback_handler = ^(id<MTL4CommitFeedback> feedback) {
    BOOL success = feedback.error == nil;
    if (!success) {
      NSLog(@"telar-gui: Metal 4 submission failed: %@", feedback.error);
    }

    dispatch_group_leave(completion_group);
    dispatch_async(dispatch_get_main_queue(), ^{
      TelarView *view = weak;
      if (view == nil || view->closed) {
        return;
      }

      view->in_flight = NO;
      view->active_drawable = nil;
      view->display_link.paused = YES;
      view->callbacks.complete(view->context, view->active_token, success);
      if (!success) {
        [view.window close];
        return;
      }

      int result = view->callbacks.pump(view->context);
      if (result < 0) {
        [view.window close];
      } else if (view->dirty || result > 0) {
        [view requestDraw];
      }
    });
  };
  return YES;
}

- (BOOL)buildPipeline {
  NSError *error = nil;
  NSString *source = [[NSString alloc] initWithBytes:shader_source
                                             length:sizeof(shader_source)
                                           encoding:NSUTF8StringEncoding];
  MTL4CompilerDescriptor *compiler_descriptor = [MTL4CompilerDescriptor new];
  id<MTL4Compiler> compiler = [device newCompilerWithDescriptor:compiler_descriptor error:&error];
  if (compiler == nil) {
    NSLog(@"telar-gui: Metal 4 compiler creation failed: %@", error);
    return NO;
  }

  MTL4LibraryDescriptor *library_descriptor = [MTL4LibraryDescriptor new];
  MTLCompileOptions *compile_options = [MTLCompileOptions new];
  compile_options.languageVersion = MTLLanguageVersion4_0;
  library_descriptor.options = compile_options;
  library_descriptor.source = source;
  library_descriptor.name = @"Telar quad shaders";
  id<MTLLibrary> library = [compiler newLibraryWithDescriptor:library_descriptor error:&error];
  if (library == nil) {
    NSLog(@"telar-gui: shader compilation failed: %@", error);
    return NO;
  }

  MTL4LibraryFunctionDescriptor *vertex = [MTL4LibraryFunctionDescriptor new];
  vertex.library = library;
  vertex.name = @"quad_vertex";
  MTL4LibraryFunctionDescriptor *fragment = [MTL4LibraryFunctionDescriptor new];
  fragment.library = library;
  fragment.name = @"quad_fragment";

  MTL4RenderPipelineDescriptor *descriptor = [MTL4RenderPipelineDescriptor new];
  descriptor.vertexFunctionDescriptor = vertex;
  descriptor.fragmentFunctionDescriptor = fragment;

  MTL4RenderPipelineColorAttachmentDescriptor *color =
      descriptor.colorAttachments[0];

  color.pixelFormat = MTLPixelFormatBGRA8Unorm;
  color.blendingState = MTL4BlendStateEnabled;
  color.rgbBlendOperation = MTLBlendOperationAdd;
  color.alphaBlendOperation = MTLBlendOperationAdd;
  color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  color.sourceAlphaBlendFactor = MTLBlendFactorOne;
  color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

  pipeline = [compiler newRenderPipelineStateWithDescriptor:descriptor
                                       compilerTaskOptions:nil
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

- (BOOL)uploadAtlas:(const telar_gui_frame *)frame {
  if (frame->atlas == NULL || frame->atlas_side == 0) {
    return YES;
  }

  if (atlas == nil || atlas.width != frame->atlas_side) {
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                     width:frame->atlas_side
                                    height:frame->atlas_side
                                 mipmapped:NO];

    descriptor.usage = MTLTextureUsageShaderRead;
    atlas = [device newTextureWithDescriptor:descriptor];
    if (atlas == nil) {
      return NO;
    }

    atlas_version = 0;
  }

  if (atlas_version == frame->atlas_version) {
    return YES;
  }

  [atlas
      replaceRegion:MTLRegionMake2D(0, 0, frame->atlas_side, frame->atlas_side)
        mipmapLevel:0
          withBytes:frame->atlas
        bytesPerRow:frame->atlas_side];

  atlas_version = frame->atlas_version;
  return YES;
}

- (void)startWakeSource {
  wake_source =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, callbacks.wake_fd, 0,
                             dispatch_get_main_queue());

  __weak TelarView *weak = self;

  dispatch_source_set_event_handler(wake_source, ^{
    TelarView *view = weak;

    if (view == nil || view->closed) {
      return;
    }

    telar_gui_drain(view->callbacks.wake_fd);
    int result = view->callbacks.pump(view->context);

    if (result < 0) {
      [view.window close];
    } else if (result > 0) {
      [view requestDraw];
    }
  });

  dispatch_resume(wake_source);
}

- (void)requestDraw {
  if (closed) {
    return;
  }

  dirty = YES;

  if (!in_flight && display_link != nil) {
    display_link.paused = NO;
    [self drawIfReady];
  }
}

// Draw immediately when the frame budget permits, e.g. [self drawIfReady].
// Otherwise the display clock, not a second timer, wakes the pending work.
- (void)drawIfReady {
  if (closed || in_flight || !dirty || self.window == nil ||
      !(self.window.occlusionState & NSWindowOcclusionStateVisible)) {
    return;
  }

  CFTimeInterval now = CACurrentMediaTime();
  if (now < next_draw) {
    return;
  }

  CAMetalLayer *layer = (CAMetalLayer *)self.layer;
  if (layer.drawableSize.width < 1 || layer.drawableSize.height < 1) {
    return;
  }

  id<CAMetalDrawable> drawable = [layer nextDrawable];
  if (drawable == nil) {
    return;
  }

  // Carry the cadence forward instead of accumulating callback jitter.
  const CFTimeInterval interval = 1.0 / 60.0;
  next_draw = now - next_draw >= interval ? now + interval : next_draw + interval;
  display_link.paused = YES;
  [self drawWithDrawable:drawable];
}

- (void)drawWithDrawable:(id<CAMetalDrawable>)drawable {
  CAMetalLayer *layer = (CAMetalLayer *)self.layer;

  if (closed || in_flight || layer == nil || self.window == nil ||
      drawable == nil) {
    return;
  }

  CGSize size = CGSizeMake(drawable.texture.width, drawable.texture.height);
  if (size.width < 1 || size.height < 1) {
    return;
  }

  telar_gui_viewport viewport = {(uint32_t)size.width, (uint32_t)size.height,
                                 (float)layer.contentsScale};
  telar_gui_frame frame;
  memset(&frame, 0, sizeof frame);

  dirty = NO;
  callbacks.render(context, viewport, &frame);
  if (![self uploadAtlas:&frame]) {
    callbacks.complete(context, frame.token, 0);
    [self.window close];
    return;
  }

  MTL4RenderPassDescriptor *pass = render_pass;

  pass.colorAttachments[0].texture = drawable.texture;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;

  pass.colorAttachments[0].clearColor =
      MTLClearColorMake(frame.background[0], frame.background[1],
                        frame.background[2], frame.background[3]);

  // Only the completion callback releases in_flight, so resetting cannot
  // invalidate command memory or resources still read by the GPU.
  [command_allocator reset];
  [commands beginCommandBufferWithAllocator:command_allocator];

  id<MTL4RenderCommandEncoder> encoder =
      [commands renderCommandEncoderWithDescriptor:pass];

  if (encoder == nil) {
    [commands endCommandBuffer];
    callbacks.complete(context, frame.token, 0);
    [self.window close];
    return;
  }

  if (frame.quad_count > 0 && frame.quads != NULL && atlas != nil) {
    NSUInteger bytes = frame.quad_count * sizeof(telar_gui_quad);

    if (quads == nil || quads.length < bytes) {
      quads = [device newBufferWithLength:MAX(bytes, (NSUInteger)4096)
                                  options:MTLResourceStorageModeShared];
    }

    if (quads == nil) {
      [encoder endEncoding];
      [commands endCommandBuffer];
      callbacks.complete(context, frame.token, 0);
      [self.window close];
      return;
    }

    memcpy(quads.contents, frame.quads, bytes);
    float viewport_size[2] = {(float)size.width, (float)size.height};

    [encoder setRenderPipelineState:pipeline];
    memcpy(viewport_buffer.contents, viewport_size, sizeof viewport_size);
    [arguments setAddress:quads.gpuAddress atIndex:0];
    [arguments setAddress:viewport_buffer.gpuAddress atIndex:1];
    [arguments setTexture:atlas.gpuResourceID atIndex:0];
    [encoder setArgumentTable:arguments atStages:MTLRenderStageVertex | MTLRenderStageFragment];

    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:6
              instanceCount:frame.quad_count];
  }

  [encoder endEncoding];
  [commands endCommandBuffer];

  // Residency makes addresses accessible; strong ivars keep resources alive.
  // The previous submission is complete before this set can change.
  [residency removeAllAllocations];
  [residency addAllocation:viewport_buffer];
  [residency addAllocation:drawable.texture];
  if (quads != nil) {
    [residency addAllocation:quads];
  }

  if (atlas != nil) {
    [residency addAllocation:atlas];
  }

  [residency commit];
  in_flight = YES;
  active_token = frame.token;
  active_drawable = drawable;
  dispatch_group_enter(gpu_work);
  [queue waitForDrawable:drawable];
  id<MTL4CommandBuffer> batch[] = {commands};
  // Commit consumes registered handlers; re-arm the same block for each frame.
  [commit_options addFeedbackHandler:feedback_handler];
  [queue commit:batch count:1 options:commit_options];
  [queue signalDrawable:drawable];
  [drawable present];
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

  [display_link invalidate];
  display_link = nil;

  if (wake_source != nil) {
    dispatch_source_cancel(wake_source);
  }

  if (in_flight) {
    dispatch_group_wait(gpu_work, DISPATCH_TIME_FOREVER);
  }

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

- (void)displayDidRefresh:(CADisplayLink *)link {
  [self drawIfReady];
}

@end

int telar_gui_run(const char *title, void *context,
                  const telar_gui_callbacks *callbacks) {
  @autoreleasepool {
    if (@available(macOS 26.0, *)) {
      // Metal 4 is the native renderer's minimum runtime API.
    } else {
      NSLog(@"telar-gui: macOS 26 or later is required for Metal 4");
      return -1;
    }

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
