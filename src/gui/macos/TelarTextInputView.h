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
@end
