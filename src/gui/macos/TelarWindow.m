#import "TelarWindow.h"

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
  for (NSNumber *button in @[@(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton)]) {
    [self standardWindowButton:button.unsignedIntegerValue].hidden = !visible;
  }

  if (!NSEqualRects(self.frame, frame)) {
    [self setFrame:frame display:YES];
  }
  if (responder != nil && self.firstResponder != responder) {
    [self makeFirstResponder:responder];
  }
  if (was_key && !self.isKeyWindow) {
    [self makeKeyWindow];
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
