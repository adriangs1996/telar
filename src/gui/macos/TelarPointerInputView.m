#import "TelarPointerInputView.h"
#import "TelarPointerCursor.h"
#include <math.h>

static uint32_t pointer_modifiers(NSEventModifierFlags flags) {
  return ((flags & NSEventModifierFlagShift) ? 1 : 0) |
         ((flags & NSEventModifierFlagOption) ? 2 : 0) |
         ((flags & NSEventModifierFlagControl) ? 4 : 0) |
         ((flags & NSEventModifierFlagCommand) ? 8 : 0);
}

@implementation TelarPointerInputView {
  NSTrackingArea *pointer_tracking;
  BOOL pointer_inside;
  telar_gui_input last_pointer;
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (pointer_tracking != nil) {
    [self removeTrackingArea:pointer_tracking];
  }

  pointer_tracking = [[NSTrackingArea alloc]
      initWithRect:NSZeroRect
           options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                   NSTrackingCursorUpdate | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
             owner:self
          userInfo:nil];
  [self addTrackingArea:pointer_tracking];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (uint32_t)desiredPointerShape {
  return 0;
}

- (void)refreshPointerCursor {
  if (!pointer_inside || !self.window.isKeyWindow) {
    return;
  }

  NSCursor *cursor = telar_pointer_cursor([self desiredPointerShape]);
  if (NSCursor.currentCursor != cursor) {
    [cursor set];
  }
}

- (BOOL)sendInput:(telar_gui_input)event {
  BOOL accepted = [super sendInput:event];
  [self refreshPointerCursor];
  return accepted;
}

- (void)resetPointer {
  if (!pointer_inside) {
    return;
  }

  pointer_inside = NO;
  last_pointer.code = 7;
  last_pointer.mods = 0;
  [self sendInput:last_pointer];
  [NSCursor.arrowCursor set];
}

- (void)stopInput {
  [self resetPointer];
  [super stopInput];
}

- (telar_gui_input)pointerAtPoint:(NSPoint)point {
  CGFloat scale = self.window.backingScaleFactor;
  return (telar_gui_input){
      .kind = 6, .code = 6, .phase = 1,
      .x = point.x * scale,
      .y = (self.isFlipped ? point.y : self.bounds.size.height - point.y) * scale};
}

- (BOOL)sendPointerInput:(telar_gui_input)input atPoint:(NSPoint)point {
  BOOL was_inside = pointer_inside;
  pointer_inside = input.code != 7 && NSPointInRect(point, self.bounds);
  last_pointer = input;
  if (was_inside && !pointer_inside) {
    [NSCursor.arrowCursor set];
  }

  return [self sendInput:input];
}

- (void)restorePointer {
  if (!self.window.isKeyWindow) {
    return;
  }

  NSPoint point = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
  if (!NSPointInRect(point, self.bounds)) {
    [self resetPointer];
    return;
  }

  telar_gui_input input = [self pointerAtPoint:point];
  input.mods = pointer_modifiers(NSEvent.modifierFlags);
  [self sendPointerInput:input atPoint:point];
}

- (BOOL)sendPointer:(NSEvent *)event code:(uint32_t)code {
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  telar_gui_input input = [self pointerAtPoint:point];
  input.code = code;
  input.button = event.buttonNumber == 1 ? 2 : event.buttonNumber == 2 ? 1 : 0;
  input.mods = pointer_modifiers(event.modifierFlags);
  return [self sendPointerInput:input atPoint:point];
}

- (void)flagsChanged:(NSEvent *)event {
  if (pointer_inside) {
    last_pointer.code = 6;
    last_pointer.button = 0;
    last_pointer.mods = pointer_modifiers(event.modifierFlags);
    [self sendInput:last_pointer];
  }
}

- (void)mouseEntered:(NSEvent *)event {
  [self sendPointer:event code:6];
}

- (void)mouseExited:(NSEvent *)event {
  [self sendPointer:event code:7];
}

- (void)cursorUpdate:(NSEvent *)event {
  [self refreshPointerCursor];
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

static uint32_t scroll_phase(NSEventPhase phase) {
  if (phase & NSEventPhaseCancelled) return 4;
  if (phase & NSEventPhaseEnded) return 3;
  if (phase & (NSEventPhaseBegan | NSEventPhaseMayBegin)) return 1;
  if (phase & (NSEventPhaseChanged | NSEventPhaseStationary)) return 2;
  return 0;
}

- (void)scrollWheel:(NSEvent *)event {
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  telar_gui_input input = [self pointerAtPoint:point];
  input.kind = 8;
  input.code = 0;
  input.mods = pointer_modifiers(event.modifierFlags);
  input.precise = event.hasPreciseScrollingDeltas;
  const double scale = input.precise && self.window != nil ? self.window.backingScaleFactor : 1;
  input.delta_x = -event.scrollingDeltaX * scale;
  input.delta_y = -event.scrollingDeltaY * scale;
  input.scroll_phase = scroll_phase(event.phase);
  input.momentum_phase = scroll_phase(event.momentumPhase);
  [self sendInput:input];
}

@end
