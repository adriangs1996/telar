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
static unsigned diagram_count;
static uint32_t diagram_widths[TELAR_GUI_DIAGRAM_SLOTS], diagram_heights[TELAR_GUI_DIAGRAM_SLOTS];

static id find_control(NSArray *children, NSString *label) {
    for (id child in children) {
        if ([[child accessibilityLabel] isEqualToString:label]) return child;
        id found = find_control([child accessibilityChildren], label);
        if (found != nil) return found;
    }
    return nil;
}

static void click_control(NSView *view, NSString *label) {
    id control = find_control([view accessibilityChildren], label);
    if (control == nil) {
        fprintf(stderr, "Missing native control: %s\n", label.UTF8String);
        abort();
    }
    NSRect frame = [control accessibilityFrame];
    NSPoint location = [view.window convertPointFromScreen:NSMakePoint(NSMidX(frame), NSMidY(frame))];
    for (NSNumber *type in @[@(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp)]) {
        NSEvent *event = [NSEvent mouseEventWithType:type.unsignedIntegerValue location:location
            modifierFlags:0 timestamp:0 windowNumber:view.window.windowNumber context:nil
            eventNumber:0 clickCount:1 pressure:1];
        if (type.unsignedIntegerValue == NSEventTypeLeftMouseDown) [view mouseDown:event];
        else [view mouseUp:event];
    }
}

static void capture_region(NSRect bounds, NSString *path) {
    if (NSIsEmptyRect(bounds)) abort();
    bounds = NSInsetRect(bounds, -36, -36);
    CGFloat top = NSScreen.screens.firstObject.frame.size.height - NSMaxY(bounds);
    NSString *region = [NSString stringWithFormat:@"%.0f,%.0f,%.0f,%.0f", bounds.origin.x, top, bounds.size.width, bounds.size.height];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
    task.arguments = @[@"-x", @"-R", region, path];
    [task launchAndReturnError:nil];
    [task waitUntilExit];
    if (task.terminationStatus != 0) abort();
}

static void capture_controls(NSView *view, NSString *path) {
    NSRect bounds = NSZeroRect;
    for (id child in [view accessibilityChildren]) bounds = NSUnionRect(bounds, [child accessibilityFrame]);
    capture_region(bounds, path);
}

static void check_tabs(NSView *view, NSDictionary *action) {
    CGFloat previous = -CGFLOAT_MAX;
    NSRect bounds = NSZeroRect;
    for (NSString *label in action[@"tab_order"]) {
        id control = find_control([view accessibilityChildren], label);
        if (control == nil) abort();
        NSRect frame = [control accessibilityFrame];
        if (NSMinX(frame) <= previous) abort();
        previous = NSMinX(frame);
        bounds = NSUnionRect(bounds, frame);
    }
    if (action[@"capture_tabs"]) capture_region(bounds, action[@"capture_tabs"]);
}

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
    diagram_count = 0;
    for (unsigned i = 0; i < TELAR_GUI_DIAGRAM_SLOTS; i++) {
        diagram_widths[i] = frame->diagrams[i].width;
        diagram_heights[i] = frame->diagrams[i].height;
        if (frame->diagrams[i].pixels != NULL) diagram_count++;
    }
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

    static NSPoint saved_location;
    static BOOL saved_location_valid = NO;
    NSPoint location;
    if (action[@"control"]) {
        id control = find_control([view accessibilityChildren], action[@"control"]);
        if (control == nil) abort();
        NSRect frame = [control accessibilityFrame];
        CGFloat fraction = action[@"fraction"] ? [action[@"fraction"] doubleValue] : .5;
        location = [view.window convertPointFromScreen:NSMakePoint(NSMinX(frame) + frame.size.width * fraction, NSMidY(frame))];
    } else if ([action[@"reuse_pointer"] boolValue]) {
        if (!saved_location_valid) abort();
        location = saved_location;
    } else {
        NSArray *cell = action[@"cell"];
        if (!marker_valid || cell.count != 2) abort();
        const CGFloat scale = view.window.backingScaleFactor;
        NSPoint local = NSMakePoint((marker.x + ([cell[0] doubleValue] + .5) * marker.width) / scale,
                                   (marker.y + ([cell[1] doubleValue] + .5) * marker.height) / scale);
        if (!view.isFlipped) local.y = view.bounds.size.height - local.y;
        location = [view convertPoint:local toView:nil];
    }
    saved_location = location;
    saved_location_valid = YES;
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
    NSMutableArray *diagrams = [NSMutableArray array];
    for (unsigned i = 0; i < TELAR_GUI_DIAGRAM_SLOTS; i++) {
        if (diagram_widths[i]) [diagrams addObject:@[@(diagram_widths[i]), @(diagram_heights[i])]];
    }
    return @{@"desired_pointer": @([view desiredPointerShape]), @"native_cursor": native_cursor(),
             @"app_active": @(NSApp.isActive), @"window_key": @(view.window.isKeyWindow),
             @"viewport": @[@(viewport.width), @(viewport.height), @(viewport.scale)],
             @"view_points": @[@(view.bounds.size.width), @(view.bounds.size.height)],
             @"marker": @[@(marker.x), @(marker.y), @(marker.width), @(marker.height)],
             @"quads": @(frame_quads), @"frame_token": @(frame_token), @"horizontal_rules": lines,
             @"diagrams": diagrams};
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
                ([action[@"wait_marker"] boolValue] && !marker_valid) ||
                (action[@"wait_diagrams"] && diagram_count < [action[@"wait_diagrams"] unsignedIntValue]) || cursor_pending) {
                const NSUInteger limit = action[@"wait_seconds"] ? MAX(1, [action[@"wait_seconds"] unsignedIntegerValue]) * 7 : 80;
                if (++waiting > limit) {
                    fprintf(stderr, "GUI action %lu timed out: %s\n", (unsigned long)index, [action.description UTF8String]);
                    if (action[@"assert_pointer"]) fprintf(stderr, "pointer state: %s\n", [pointer_record(view).description UTF8String]);
                    abort();
                }
                return;
            }
            waiting = 0;
            fprintf(stderr, "GUI action %lu: %s\n", (unsigned long)index, [action.description UTF8String]);
            if (action[@"resize"]) {
                NSArray *size = action[@"resize"];
                [window setContentSize:NSMakeSize([size[0] doubleValue], [size[1] doubleValue])];
            }
            if (action[@"key"]) send_key(view, action);
            if (action[@"text"]) [(id<NSTextInputClient>)view insertText:action[@"text"] replacementRange:NSMakeRange(NSNotFound, 0)];
            if (action[@"click_label"]) click_control(view, action[@"click_label"]);
            if (action[@"signal"] && ![[NSData data] writeToFile:action[@"signal"] atomically:YES]) abort();
            if (action[@"expect_clipboard"] && ![[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] isEqualToString:action[@"expect_clipboard"]]) abort();
            if (action[@"expect_value"]) {
                NSDictionary *expected = action[@"expect_value"];
                id control = find_control([view accessibilityChildren], expected[@"label"]);
                if (control == nil || ![[control accessibilityValue] isEqual:expected[@"value"]]) abort();
            }
            if (action[@"capture_controls"]) capture_controls(view, action[@"capture_controls"]);
            if (action[@"tab_order"]) check_tabs(view, action);
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
