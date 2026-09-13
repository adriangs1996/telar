#pragma once
#import "TelarTextInputView.h"

// Native coordinates and scroll accumulation; client policy stays in Zig.
@interface TelarPointerInputView : TelarTextInputView
// The host reads client state here, e.g. return callbacks.pointer_shape(context).
- (uint32_t)desiredPointerShape;
// Reapply after input or client updates without scheduling a GPU presentation.
- (void)refreshPointerCursor;
// Focus transitions clear hover ownership or resample a stationary pointer.
- (void)resetPointer;
- (void)restorePointer;
@end
