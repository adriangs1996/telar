#import "TelarView.h"
#import "TelarMetalRenderer.h"
#import "TelarWindowBackground.h"
#import <QuartzCore/CADisplayLink.h>
#include <string.h>

@implementation TelarView {
  TelarMetalRenderer *renderer;
  void *context;
  telar_gui_callbacks callbacks;
  dispatch_source_t wake_source;
  dispatch_source_t animation_source;
  BOOL dirty, closed;
  CADisplayLink *display_link;
  CFTimeInterval next_draw;
}

- (instancetype)initWithFrame:(NSRect)frame
                      context:(void *)render_context
                    callbacks:(const telar_gui_callbacks *)callback_table {
  int (*input)(void *, telar_gui_input) = callback_table->input;

  self = [super initWithFrame:frame
                 inputHandler:^BOOL(telar_gui_input event) {
                   return input(render_context, event) != 0;
                 }];

  if (self == nil) {
    return nil;
  }

  context = render_context;
  callbacks = *callback_table;
  __weak TelarView *weak = self;

  renderer = [[TelarMetalRenderer alloc]
      initWithCompletion:^(uint64_t token, BOOL success) {
        TelarView *view = weak;
        if (view == nil || view->closed) {
          return;
        }

        view->display_link.paused = YES;
        view->callbacks.complete(view->context, token, success);
        if (!success) {
          [view.window close];
          return;
        }

        [view pumpEvents];
      }];

  if (renderer == nil) {
    return nil;
  }

  self.wantsLayer = YES;
  self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;

  display_link = [self displayLinkWithTarget:self
                                    selector:@selector(displayDidRefresh:)];
  display_link.paused = YES;
  display_link.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);

  [display_link addToRunLoop:[NSRunLoop mainRunLoop]
                     forMode:NSRunLoopCommonModes];

  return self;
}

- (CALayer *)makeBackingLayer {
  CAMetalLayer *layer = [CAMetalLayer layer];
  layer.device = renderer.device;
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
    [view pumpEvents];
  });

  dispatch_resume(wake_source);

  animation_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                             dispatch_get_main_queue());
  dispatch_source_set_timer(animation_source, DISPATCH_TIME_FOREVER,
                            DISPATCH_TIME_FOREVER, 0);
  dispatch_source_set_event_handler(animation_source, ^{ [weak pumpEvents]; });
  dispatch_resume(animation_source);
  [self scheduleWake];
}

- (void)requestDraw {
  if (closed) {
    return;
  }

  dirty = YES;

  if (!renderer.isBusy && display_link != nil) {
    display_link.paused = NO;
    [self drawIfReady];
  }
}

// Draw immediately when the frame budget permits, e.g. [self drawIfReady].
// Otherwise the display clock, not a second timer, wakes the pending work.
- (void)drawIfReady {
  if (closed || renderer.isBusy || !dirty || self.window == nil ||
      !(self.window.occlusionState & NSWindowOcclusionStateVisible)) {
    if (self.window != nil && !(self.window.occlusionState & NSWindowOcclusionStateVisible)) {
      display_link.paused = YES;
    }
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
  next_draw =
      now - next_draw >= interval ? now + interval : next_draw + interval;
  display_link.paused = YES;
  [self drawWithDrawable:drawable];
}

- (void)drawWithDrawable:(id<CAMetalDrawable>)drawable {
  CAMetalLayer *layer = (CAMetalLayer *)self.layer;

  if (closed || renderer.isBusy || layer == nil || self.window == nil ||
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
  if (frame.token == 0) {
    dirty = YES;
    return;
  }
  [self.backgroundView applyFrame:&frame];
  if (![renderer renderFrame:&frame drawable:drawable]) {
    callbacks.complete(context, frame.token, 0);
    [self.window close];
    return;
  }
}

- (void)windowWillClose:(NSNotification *)notification {
  closed = YES;
  if (animation_source != nil) {
    dispatch_source_cancel(animation_source);
  }
  [self stopInput];

  [display_link invalidate];
  display_link = nil;

  if (wake_source != nil) {
    dispatch_source_cancel(wake_source);
  }

  [renderer shutdown];

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

// One deadline from Zig, e.g. the cursor's next phase. No 60 Hz idle polling.
- (void)scheduleWake {
  if (closed || animation_source == nil) {
    return;
  }
  uint32_t delay = 0;
  if (callbacks.wakeup_after != NULL && self.window != nil &&
      (self.window.occlusionState & NSWindowOcclusionStateVisible)) {
    delay = callbacks.wakeup_after(context);
  }
  dispatch_source_set_timer(animation_source,
      delay ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_MSEC) : DISPATCH_TIME_FOREVER,
      DISPATCH_TIME_FOREVER, 0);
}

- (void)pumpEvents {
  if (closed) {
    return;
  }
  int result = callbacks.pump(context);
  if (result < 0) {
    [self.window close];
    return;
  }
  if (dirty || result > 0) {
    [self requestDraw];
  }
  [self scheduleWake];
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
  callbacks.input(context, (telar_gui_input){.kind = 5, .code = 1, .phase = 1});
  [self requestDraw];
  [self scheduleWake];
}

- (void)windowDidResignKey:(NSNotification *)notification {
  if (!closed) {
    callbacks.input(context, (telar_gui_input){.kind = 5, .code = 0, .phase = 1});
    [self requestDraw];
    [self scheduleWake];
  }
}

- (void)windowDidChangeOcclusionState:(NSNotification *)notification {
  if (!(self.window.occlusionState & NSWindowOcclusionStateVisible)) {
    display_link.paused = YES;
  } else {
    [self requestDraw];
  }
  [self scheduleWake];
}

@end
