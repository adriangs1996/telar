#import "TelarPointerInputView.h"
#include <math.h>

@implementation TelarPointerInputView {
  NSTrackingArea *pointer_tracking;
  double scroll_remainder;
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (pointer_tracking != nil) {
    [self removeTrackingArea:pointer_tracking];
  }

  pointer_tracking = [[NSTrackingArea alloc]
      initWithRect:NSZeroRect
           options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
             owner:self
          userInfo:nil];
  [self addTrackingArea:pointer_tracking];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (BOOL)sendPointer:(NSEvent *)event code:(uint32_t)code {
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  CGFloat scale = self.window.backingScaleFactor;
  uint32_t button = event.buttonNumber == 1 ? 2 : event.buttonNumber == 2 ? 1 : 0;
  uint32_t mods = ((event.modifierFlags & NSEventModifierFlagShift) ? 1 : 0) |
                  ((event.modifierFlags & NSEventModifierFlagOption) ? 2 : 0) |
                  ((event.modifierFlags & NSEventModifierFlagControl) ? 4 : 0);
  return [self sendInput:(telar_gui_input){
      .kind = 6, .code = code, .mods = mods, .phase = 1, .button = button,
      .x = point.x * scale,
      .y = (self.isFlipped ? point.y : self.bounds.size.height - point.y) * scale}];
}

- (void)mouseDown:(NSEvent *)event {
  [self.window makeFirstResponder:self];
  [self sendPointer:event code:1];
}

- (void)mouseUp:(NSEvent *)event {
  [self sendPointer:event code:2];
}

- (void)mouseDragged:(NSEvent *)event {
  [self sendPointer:event code:3];
}

- (void)rightMouseDown:(NSEvent *)event {
  [self mouseDown:event];
}

- (void)rightMouseUp:(NSEvent *)event {
  [self mouseUp:event];
}

- (void)rightMouseDragged:(NSEvent *)event {
  [self mouseDragged:event];
}

- (void)otherMouseDown:(NSEvent *)event {
  [self mouseDown:event];
}

- (void)otherMouseUp:(NSEvent *)event {
  [self mouseUp:event];
}

- (void)otherMouseDragged:(NSEvent *)event {
  [self mouseDragged:event];
}

- (void)mouseMoved:(NSEvent *)event {
  [self sendPointer:event code:6];
}

- (void)scrollWheel:(NSEvent *)event {
  if (event.phase == NSEventPhaseBegan) {
    scroll_remainder = 0;
  }

  double delta = event.scrollingDeltaY;
  if (event.hasPreciseScrollingDeltas) {
    delta /= 10.0;
  }

  scroll_remainder = fmax(-32, fmin(32, scroll_remainder + delta));
  while (fabs(scroll_remainder) >= 1) {
    BOOL up = scroll_remainder > 0;
    if (![self sendPointer:event code:up ? 4 : 5]) {
      scroll_remainder = 0;
      return;
    }

    scroll_remainder += up ? -1 : 1;
  }
}
@end
