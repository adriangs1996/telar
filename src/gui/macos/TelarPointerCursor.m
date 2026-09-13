#import "TelarPointerCursor.h"

static NSCursor *cursor_for_shape(uint32_t shape) {
  switch (shape) {
  case 1: return NSCursor.contextualMenuCursor;
  case 3: return NSCursor.pointingHandCursor;
  case 6: // AppKit has no cell cursor; crosshair preserves precise targeting.
  case 7: return NSCursor.crosshairCursor;
  case 8: return NSCursor.IBeamCursor;
  case 9: return NSCursor.IBeamCursorForVerticalLayout;
  case 10: return NSCursor.dragLinkCursor;
  case 11: return NSCursor.dragCopyCursor;
  case 12: // No move/all-scroll cursor; the open hand indicates movement.
  case 15:
  case 17: return NSCursor.openHandCursor;
  case 13:
  case 14: return NSCursor.operationNotAllowedCursor;
  case 16: return NSCursor.closedHandCursor;
  case 18: return NSCursor.columnResizeCursor;
  case 19: return NSCursor.rowResizeCursor;
  case 20: return [NSCursor rowResizeCursorInDirections:NSVerticalDirectionsUp];
  case 21: return [NSCursor columnResizeCursorInDirections:NSHorizontalDirectionsRight];
  case 22: return [NSCursor rowResizeCursorInDirections:NSVerticalDirectionsDown];
  case 23: return [NSCursor columnResizeCursorInDirections:NSHorizontalDirectionsLeft];
  case 24:
  case 30: return [NSCursor frameResizeCursorFromPosition:NSCursorFrameResizePositionTopRight
                                           inDirections:NSCursorFrameResizeDirectionsAll];
  case 25:
  case 31: return [NSCursor frameResizeCursorFromPosition:NSCursorFrameResizePositionTopLeft
                                           inDirections:NSCursorFrameResizeDirectionsAll];
  case 26: return [NSCursor frameResizeCursorFromPosition:NSCursorFrameResizePositionBottomRight
                                           inDirections:NSCursorFrameResizeDirectionsAll];
  case 27: return [NSCursor frameResizeCursorFromPosition:NSCursorFrameResizePositionBottomLeft
                                           inDirections:NSCursorFrameResizeDirectionsAll];
  case 28: return [NSCursor frameResizeCursorFromPosition:NSCursorFrameResizePositionRight
                                           inDirections:NSCursorFrameResizeDirectionsAll];
  case 29: return [NSCursor frameResizeCursorFromPosition:NSCursorFrameResizePositionTop
                                           inDirections:NSCursorFrameResizeDirectionsAll];
  case 32: return NSCursor.zoomInCursor;
  case 33: return NSCursor.zoomOutCursor;
  case 0:
  case 2: // Help, progress and wait have no public AppKit cursor equivalents.
  case 4:
  case 5:
  default: return NSCursor.arrowCursor;
  }
}

NSCursor *telar_pointer_cursor(uint32_t shape) {
  static NSCursor *cursors[34];
  static BOOL initialized;
  if (!initialized) {
    for (uint32_t i = 0; i < 34; i++) {
      cursors[i] = cursor_for_shape(i);
    }

    initialized = YES;
  }

  return cursors[shape < 34 ? shape : 0];
}
