#include "gui_view.h"
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
        NSView *view = terminal_view(window.contentView);
        send_command(view, @"echo $$ > child.pid; stty size > before; printf input-ok > typed");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            // Resize the content view directly so a tiling window manager cannot undo it.
            view.autoresizingMask = NSViewNotSizable;
            [view setFrameSize:NSMakeSize(640, 360)];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 3), dispatch_get_main_queue(), ^{
                send_command(view, @"stty size > after");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
                    const char *capture = getenv("TELAR_GUI_CAPTURE");
                    if (capture == NULL) { [window close]; return; }
                    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                    [window setContentSize:NSMakeSize(800, 500)];
                    view.frame = NSMakeRect(0, 0, window.contentLayoutRect.size.width, window.contentLayoutRect.size.height);
                    send_command(view, @"printf '\\033[2J\\033[HTelar GUI - configured appearance\\n\\n\\033[31mRed \\033[32mGreen \\033[34mBlue\\033[0m\\nUnicode: café λ →\\n\\033[2 q'");
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
                        NSTask *task = [[NSTask alloc] init];
                        task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
                        task.arguments = @[@"-x", @"-o", @"-l", [NSString stringWithFormat:@"%ld", (long)window.windowNumber], [NSString stringWithUTF8String:capture]];
                        [task launchAndReturnError:nil];
                        [task waitUntilExit];
                        [window close];
                    });
                });
            });
        });
    });
}
