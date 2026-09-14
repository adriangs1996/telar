#pragma once
#include "../native/telar_gui.h"
#import <AppKit/AppKit.h>

// The handler consumes borrowed text synchronously, on the main thread.
typedef BOOL (^TelarInputHandler)(telar_gui_input event);

@interface TelarTextInputView : NSView <NSTextInputClient>
- (instancetype)initWithFrame:(NSRect)frame
                 inputHandler:(TelarInputHandler)handler;
// Disconnect the borrowed client context, e.g. [view stopInput] on close.
- (void)stopInput;
// Release physical leases when the window loses keyboard focus.
- (void)releasePressedKeys;
// Subclasses use the same bounded semantic admission, e.g. [self sendInput:event].
- (BOOL)sendInput:(telar_gui_input)event;
// Refresh the synchronous Cocoa mirror from the current Zig editing owner.
- (void)refreshTextContext;
// -1 preserves the mirror while admitted input is still awaiting Zig dispatch.
- (int)copyTextContext:(telar_gui_text_context *)output;
@end
