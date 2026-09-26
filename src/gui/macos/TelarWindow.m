#import "TelarWindow.h"

// Traffic-light geometry over a transparent titlebar, in points: the first
// button's left edge, the distance between button origins and the room kept
// after the last one before Telar's own controls start.
static const CGFloat controls_lead = 14;
static const CGFloat controls_pitch = 20;
static const CGFloat controls_trail = 10;

@implementation TelarWindow {
  BOOL configured, visible, applied_visible, changing_fullscreen;
}

- (BOOL)titlebarVisible {
  return !configured || visible;
}

// Keep the titled window's focus/fullscreen behavior while extending content
// into its decoration. Example: window.titlebarVisible = NO.
- (void)setTitlebarVisible:(BOOL)value {
  if (!configured) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[NSWindowWillEnterFullScreenNotification, NSWindowWillExitFullScreenNotification]) {
      [center addObserver:self selector:@selector(fullscreenWillChange:) name:name object:self];
    }
    for (NSNotificationName name in @[NSWindowDidEnterFullScreenNotification, NSWindowDidExitFullScreenNotification]) {
      [center addObserver:self selector:@selector(fullscreenDidChange:) name:name object:self];
    }
    configured = YES;
    applied_visible = YES;
  }

  visible = value;
  [self applyTitlebar:NO];
}

- (void)applyTitlebar:(BOOL)force {
  if (changing_fullscreen || (self.styleMask & NSWindowStyleMaskFullScreen)) {
    return;
  }

  NSWindowStyleMask style = self.styleMask;
  style = visible ? style & ~NSWindowStyleMaskFullSizeContentView : style | NSWindowStyleMaskFullSizeContentView;
  if (!force && applied_visible == visible && self.styleMask == style &&
      self.titleVisibility == (visible ? NSWindowTitleVisible : NSWindowTitleHidden)) {
    return;
  }

  NSRect frame = self.frame;
  NSResponder *responder = self.firstResponder;
  BOOL was_key = self.isKeyWindow;
  applied_visible = visible;
  self.styleMask = style;
  self.titlebarAppearsTransparent = !visible;
  self.titleVisibility = visible ? NSWindowTitleVisible : NSWindowTitleHidden;

  if (!NSEqualRects(self.frame, frame)) {
    [self setFrame:frame display:YES];
  }
  [self placeControls];
  if (responder != nil && self.firstResponder != responder) {
    [self makeFirstResponder:responder];
  }
  if (was_key && !self.isKeyWindow) {
    [self makeKeyWindow];
  }
}

- (void)setControlsHeight:(CGFloat)height {
  if (_controlsHeight == height) {
    return;
  }

  _controlsHeight = height;
  [self placeControls];
}

- (BOOL)controlsOverContent {
  return configured && !visible && !changing_fullscreen && !(self.styleMask & NSWindowStyleMaskFullScreen);
}

- (CGFloat)controlsInset {
  if (![self controlsOverContent]) {
    return 0;
  }

  NSButton *zoom = [self standardWindowButton:NSWindowZoomButton];
  return controls_lead + 2 * controls_pitch + (zoom != nil ? zoom.frame.size.width : 14) + controls_trail;
}

// Over a transparent titlebar the lights move into Telar's navigation row:
// the titlebar container takes the row's height and each light is centered in
// it at a fixed pitch. AppKit may lay the container out again on resize, so
// every paint calls this and it writes only what differs.
- (void)placeControls {
  if (![self controlsOverContent] || self.controlsHeight <= 0) {
    return;
  }

  NSButton *close = [self standardWindowButton:NSWindowCloseButton];
  NSView *container = close.superview.superview;
  if (close == nil || container == nil) {
    return;
  }

  NSRect bar = container.frame;
  const CGFloat height = self.controlsHeight;
  const CGFloat top = self.frame.size.height - height;
  if (bar.size.height != height || bar.origin.y != top) {
    bar.size.height = height;
    bar.origin.y = top;
    container.frame = bar;
  }

  NSArray *kinds = @[@(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton)];
  for (NSUInteger index = 0; index < kinds.count; index++) {
    NSButton *button = [self standardWindowButton:[kinds[index] unsignedIntegerValue]];
    NSPoint origin = NSMakePoint(controls_lead + index * controls_pitch, round((height - button.frame.size.height) / 2));
    if (button.hidden) {
      button.hidden = NO;
    }
    if (!NSEqualPoints(button.frame.origin, origin)) {
      [button setFrameOrigin:origin];
    }
  }
}

// The hidden title has no reserved layout/drag strip. FullSizeContentView
// extends the view but AppKit still insets this rectangle by default.
// Fullscreen keeps AppKit's own geometry, as in Ghostty's hidden titlebar style.
- (NSRect)contentLayoutRect {
  NSRect rect = super.contentLayoutRect;
  if ((self.styleMask & NSWindowStyleMaskFullSizeContentView) && !(self.styleMask & NSWindowStyleMaskFullScreen)) {
    rect.origin.y = 0;
    rect.size.height = self.frame.size.height;
  }
  return rect;
}

- (void)fullscreenWillChange:(NSNotification *)notification {
  changing_fullscreen = YES;
}

- (void)fullscreenDidChange:(NSNotification *)notification {
  [self finishFullscreenTransition];
}

// A completed or failed AppKit transition releases pending decoration changes.
// Example: [window finishFullscreenTransition].
- (void)finishFullscreenTransition {
  changing_fullscreen = NO;
  [self applyTitlebar:YES];
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
}
@end
