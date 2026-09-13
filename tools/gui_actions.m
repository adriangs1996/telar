// Drives a native window through AppKit input without changing production code.
#include "gui_view.h"
#include "../src/gui/native/telar_gui.h"
#import <objc/runtime.h>
#include <math.h>
#include <stdlib.h>

@interface NSView (TelarPointerProbe)
- (uint32_t)desiredPointerShape;
@end

static IMP original_init;
static void (*original_render)(void *, telar_gui_viewport, telar_gui_frame *);
static telar_gui_viewport viewport;
static telar_gui_quad marker;
static BOOL marker_valid;
static unsigned marker_rgb[3], frame_quads;
static uint64_t frame_token;
static telar_gui_quad rules[256];
static unsigned rule_count;

static NSEventModifierFlags modifiers(NSDictionary *action) {
    NSEventModifierFlags flags = 0;
    if ([action[@"ctrl"] boolValue]) flags |= NSEventModifierFlagControl;
    if ([action[@"shift"] boolValue]) flags |= NSEventModifierFlagShift;
    if ([action[@"alt"] boolValue]) flags |= NSEventModifierFlagOption;
    if ([action[@"cmd"] boolValue]) flags |= NSEventModifierFlagCommand;
    return flags;
}

static void send_key(NSView *view, NSDictionary *action) {
    NSString *characters = action[@"key"];
    NSEventModifierFlags flags = modifiers(action);
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

// A child paints one unique background cell. Its actual quad locates terminal
// cell coordinates across font changes, padding and native chrome offsets.
static void render(void *context, telar_gui_viewport size, telar_gui_frame *frame) {
    original_render(context, size, frame);
    if (!frame->token) return;
    viewport = size;
    frame_quads = frame->quad_count;
    frame_token = frame->token;
    marker_valid = NO;
    rule_count = 0;
    for (uint32_t i = 0; i < frame->quad_count; i++) {
        const telar_gui_quad *quad = &frame->quads[i];
        if (quad->height == 1 && quad->u0 == quad->u1) {
            if (rule_count == sizeof rules / sizeof rules[0]) abort();
            rules[rule_count++] = *quad;
        }
        if (fabsf(quad->r * 255 - marker_rgb[0]) < .01 &&
            fabsf(quad->g * 255 - marker_rgb[1]) < .01 &&
            fabsf(quad->b * 255 - marker_rgb[2]) < .01 &&
            quad->width > 0 && quad->height > 0 && quad->u0 == quad->u1) {
            marker = *quad;
            marker_valid = YES;
        }
    }
}

static id initialize(id self, SEL selector, NSRect frame, void *context, const telar_gui_callbacks *callbacks) {
    original_render = callbacks->render;
    telar_gui_callbacks wrapped = *callbacks;
    wrapped.render = render;
    return ((id (*)(id, SEL, NSRect, void *, const telar_gui_callbacks *))original_init)(self, selector, frame, context, &wrapped);
}

static NSString *native_cursor(void) {
    NSCursor *cursor = NSCursor.currentCursor;
    if (cursor == NSCursor.IBeamCursor) return @"text";
    if (cursor == NSCursor.pointingHandCursor) return @"pointer";
    if (cursor == NSCursor.crosshairCursor) return @"crosshair";
    if (cursor == NSCursor.columnResizeCursor) return @"col_resize";
    if (cursor == NSCursor.operationNotAllowedCursor) return @"not_allowed";
    if (cursor == NSCursor.arrowCursor) return @"default";
    return @"other";
}

static void send_pointer(NSView *view, NSDictionary *action) {
    if (!NSApp.isActive || !view.window.isKeyWindow) {
        fprintf(stderr, "Native pointer probe lost application/window focus before input\n");
        abort();
    }
    NSString *kind = action[@"pointer"];
    NSEventModifierFlags flags = modifiers(action);
    if ([kind isEqualToString:@"modifiers"]) {
        [view flagsChanged:[NSEvent keyEventWithType:NSEventTypeFlagsChanged location:NSZeroPoint
            modifierFlags:flags timestamp:0 windowNumber:view.window.windowNumber context:nil
            characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:55]];
        return;
    }

    NSArray *cell = action[@"cell"];
    if (!marker_valid || cell.count != 2) abort();
    const CGFloat scale = view.window.backingScaleFactor;
    NSPoint local = NSMakePoint((marker.x + ([cell[0] doubleValue] + .5) * marker.width) / scale,
                               (marker.y + ([cell[1] doubleValue] + .5) * marker.height) / scale);
    if (!view.isFlipped) local.y = view.bounds.size.height - local.y;
    const NSPoint location = [view convertPoint:local toView:nil];
    NSDictionary *types = @{@"enter": @(NSEventTypeMouseEntered), @"leave": @(NSEventTypeMouseExited),
        @"move": @(NSEventTypeMouseMoved), @"press": @(NSEventTypeLeftMouseDown),
        @"drag": @(NSEventTypeLeftMouseDragged), @"release": @(NSEventTypeLeftMouseUp)};
    NSNumber *number = types[kind];
    if (number == nil) abort();
    const NSEventType type = number.unsignedIntegerValue;
    NSEvent *event;
    if (type == NSEventTypeMouseEntered || type == NSEventTypeMouseExited) {
        event = [NSEvent enterExitEventWithType:type location:location modifierFlags:flags timestamp:0
            windowNumber:view.window.windowNumber context:nil eventNumber:1 trackingNumber:0 userData:NULL];
    } else {
        event = [NSEvent mouseEventWithType:type location:location modifierFlags:flags timestamp:0
            windowNumber:view.window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:type == NSEventTypeLeftMouseUp ? 0 : 1];
    }
    if (type == NSEventTypeMouseEntered) [view mouseEntered:event];
    else if (type == NSEventTypeMouseExited) [view mouseExited:event];
    else if (type == NSEventTypeMouseMoved) [view mouseMoved:event];
    else if (type == NSEventTypeLeftMouseDown) [view mouseDown:event];
    else if (type == NSEventTypeLeftMouseDragged) [view mouseDragged:event];
    else [view mouseUp:event];
}

static NSDictionary *pointer_record(NSView *view) {
    NSMutableArray *lines = [NSMutableArray arrayWithCapacity:rule_count];
    for (unsigned i = 0; i < rule_count; i++) {
        [lines addObject:@[@(rules[i].x), @(rules[i].y), @(rules[i].width), @(rules[i].height)]];
    }
    return @{@"desired_pointer": @([view desiredPointerShape]), @"native_cursor": native_cursor(),
             @"app_active": @(NSApp.isActive), @"window_key": @(view.window.isKeyWindow),
             @"viewport": @[@(viewport.width), @(viewport.height), @(viewport.scale)],
             @"view_points": @[@(view.bounds.size.width), @(view.bounds.size.height)],
             @"marker": @[@(marker.x), @(marker.y), @(marker.width), @(marker.height)],
             @"quads": @(frame_quads), @"frame_token": @(frame_token), @"horizontal_rules": lines};
}

__attribute__((constructor)) static void install(void) {
    const char *script = getenv("TELAR_GUI_ACTIONS");
    if (script == NULL || ![NSProcessInfo.processInfo.arguments containsObject:@"gui"]) return;
    NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:script]];
    NSArray *actions = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![actions isKindOfClass:NSArray.class]) abort();
    const char *color = getenv("TELAR_GUI_MARKER");
    if (color != NULL) {
        if (sscanf(color, "%u,%u,%u", &marker_rgb[0], &marker_rgb[1], &marker_rgb[2]) != 3) abort();
        Method method = class_getInstanceMethod(objc_getClass("TelarView"), sel_registerName("initWithFrame:context:callbacks:"));
        if (method == NULL) abort();
        original_init = method_setImplementation(method, (IMP)initialize);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 2), dispatch_get_main_queue(), ^{
        NSWindow *window = NSApp.windows.firstObject;
        NSView *view = terminal_view(window.contentView);
        if (view == nil) abort();
        __block NSUInteger index = 0;
        __block NSUInteger waiting = 0;
        [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *timer) {
            if (index == actions.count) { [timer invalidate]; [window close]; return; }
            NSDictionary *action = actions[index];
            const BOOL cursor_pending = action[@"assert_pointer"] != nil &&
                ([view desiredPointerShape] != [action[@"assert_pointer"] unsignedIntValue] ||
                 (action[@"native_cursor"] != nil && ![native_cursor() isEqualToString:action[@"native_cursor"]]));
            if (cursor_pending && (!NSApp.isActive || !window.isKeyWindow)) {
                fprintf(stderr, "Native pointer assertion lost application/window focus: %s\n", [pointer_record(view).description UTF8String]);
                abort();
            }
            if ((action[@"wait"] && ![NSFileManager.defaultManager fileExistsAtPath:action[@"wait"]]) ||
                ([action[@"wait_marker"] boolValue] && !marker_valid) || cursor_pending) {
                if (++waiting > 80) {
                    fprintf(stderr, "GUI action %lu timed out: %s\n", (unsigned long)index, [action.description UTF8String]);
                    if (action[@"assert_pointer"]) fprintf(stderr, "pointer state: %s\n", [pointer_record(view).description UTF8String]);
                    abort();
                }
                return;
            }
            waiting = 0;
            fprintf(stderr, "GUI action %lu: %s\n", (unsigned long)index, [action.description UTF8String]);
            if (action[@"key"]) send_key(view, action);
            if (action[@"text"]) [(id<NSTextInputClient>)view insertText:action[@"text"] replacementRange:NSMakeRange(NSNotFound, 0)];
            if (action[@"pointer"]) send_pointer(view, action);
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
            if (action[@"record"]) {
                NSData *record = [NSJSONSerialization dataWithJSONObject:pointer_record(view) options:NSJSONWritingPrettyPrinted error:nil];
                if (![record writeToFile:action[@"record"] atomically:YES]) abort();
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
