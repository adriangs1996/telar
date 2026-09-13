// Drives a native window through AppKit input without changing production code.
#include "gui_view.h"
#include <stdlib.h>

static void send_key(NSView *view, NSDictionary *action) {
    NSString *characters = action[@"key"];
    NSEventModifierFlags flags = 0;
    if ([action[@"ctrl"] boolValue]) flags |= NSEventModifierFlagControl;
    if ([action[@"shift"] boolValue]) flags |= NSEventModifierFlagShift;
    if ([action[@"alt"] boolValue]) flags |= NSEventModifierFlagOption;
    NSString *phase = action[@"phase"];
    NSArray *types = phase == nil ? @[@(NSEventTypeKeyDown), @(NSEventTypeKeyUp)] :
        @[[phase isEqualToString:@"release"] ? @(NSEventTypeKeyUp) : @(NSEventTypeKeyDown)];
    for (NSNumber *type in types) {
        NSEvent *event = [NSEvent keyEventWithType:type.unsignedIntegerValue
            location:NSZeroPoint modifierFlags:flags timestamp:0
            windowNumber:view.window.windowNumber context:nil characters:characters
            charactersIgnoringModifiers:characters isARepeat:[phase isEqualToString:@"repeat"]
            keyCode:[action[@"code"] unsignedShortValue]];
        if (type.unsignedIntegerValue == NSEventTypeKeyDown) [view keyDown:event];
        else [view keyUp:event];
    }
}

__attribute__((constructor)) static void install(void) {
    const char *script = getenv("TELAR_GUI_ACTIONS");
    if (script == NULL || ![NSProcessInfo.processInfo.arguments containsObject:@"gui"]) return;
    NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:script]];
    NSArray *actions = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![actions isKindOfClass:NSArray.class]) abort();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 2), dispatch_get_main_queue(), ^{
        NSWindow *window = NSApp.windows.firstObject;
        NSView *view = terminal_view(window.contentView);
        if (view == nil) abort();
        __block NSUInteger index = 0;
        __block NSUInteger waiting = 0;
        [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *timer) {
            if (index == actions.count) { [timer invalidate]; [window close]; return; }
            NSDictionary *action = actions[index];
            if (action[@"wait"] && ![NSFileManager.defaultManager fileExistsAtPath:action[@"wait"]]) {
                if (++waiting > 80) {
                    fprintf(stderr, "GUI action %lu timed out: %s\n", (unsigned long)index, [action.description UTF8String]);
                    abort();
                }
                return;
            }
            waiting = 0;
            fprintf(stderr, "GUI action %lu: %s\n", (unsigned long)index, [action.description UTF8String]);
            if (action[@"key"]) send_key(view, action);
            if (action[@"text"]) [(id<NSTextInputClient>)view insertText:action[@"text"] replacementRange:NSMakeRange(NSNotFound, 0)];
            if (action[@"click"]) {
                NSArray *point = action[@"click"];
                NSPoint local = NSMakePoint(view.bounds.size.width * [point[0] doubleValue],
                    view.bounds.size.height * (1 - [point[1] doubleValue]));
                NSPoint location = [view convertPoint:local toView:nil];
                for (NSNumber *type in @[@(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp)]) {
                    NSEvent *event = [NSEvent mouseEventWithType:type.unsignedIntegerValue location:location
                        modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil
                        eventNumber:0 clickCount:1 pressure:1];
                    if (type.unsignedIntegerValue == NSEventTypeLeftMouseDown) [view mouseDown:event];
                    else [view mouseUp:event];
                }
            }
            if (action[@"capture"]) {
                NSTask *task = [NSTask new];
                task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
                task.arguments = @[@"-x", @"-o", @"-l", [NSString stringWithFormat:@"%ld", (long)window.windowNumber], action[@"capture"]];
                [task launchAndReturnError:nil];
                [task waitUntilExit];
            }
            index += 1;
        }];
    });
}
