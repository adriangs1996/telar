// Test-only native input, resize, and detach driver for a real runtime shell.
#import <AppKit/AppKit.h>
#include <stdlib.h>

static void send_command(NSView *view, NSString *command) {
    [(id<NSTextInputClient>)view insertText:command replacementRange:NSMakeRange(NSNotFound, 0)];
    [view keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:0 timestamp:0 windowNumber:view.window.windowNumber context:nil
        characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36]];
}

__attribute__((constructor)) static void install(void) {
    if (![NSProcessInfo.processInfo.arguments containsObject:@"gui"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 2), dispatch_get_main_queue(), ^{
        NSWindow *window = NSApp.windows.firstObject;
        NSView *view = window.contentView;
        send_command(view, @"echo $$ > child.pid; stty size > before; printf input-ok > typed");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            // Resize the content view directly so a tiling window manager cannot undo it.
            view.autoresizingMask = NSViewNotSizable;
            [view setFrameSize:NSMakeSize(640, 360)];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 3), dispatch_get_main_queue(), ^{
                send_command(view, @"stty size > after");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
                    [window close];
                });
            });
        });
    });
}
