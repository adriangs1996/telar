#include "../../../tools/gui_view.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#include "telar_gui.h"
#import "../macos/TelarTextInputView.h"
#import "../macos/TelarView.h"
#import "../macos/TelarPointerCursor.h"
#import "../macos/TelarWindow.h"
#import "../macos/TelarWindowBackground.h"
#include <stdio.h>
#include <string.h>
#include <math.h>

static int paints, delivered, discarded, inputs, failed;
static BOOL injecting, close_in_flight, closed_in_flight;
static IMP original_draw;
static CFTimeInterval deadline;
static int timer_wakes, focus_events;
static int deferred;
static unsigned appearance_phase;
static unsigned appearance_checked;
static double pointer_x, pointer_y;
static bool checking_repeat;
static int repeat_inputs;
static telar_gui_input expected_repeat;
static BOOL checking_pointer;
static unsigned pointer_inputs, pointer_queries;
static uint32_t pointer_shape;
static telar_gui_input expected_pointer;
static BOOL fullscreen_in_progress, fullscreen_exit_scheduled;
static unsigned fullscreen_checked;

static NSEvent *key_event(NSView *view, unsigned short key, NSString *text, NSEventModifierFlags mods, uint32_t phase) {
    return [NSEvent keyEventWithType:phase == 3 ? NSEventTypeKeyUp : NSEventTypeKeyDown
                           location:NSZeroPoint modifierFlags:mods timestamp:0
                       windowNumber:view.window.windowNumber context:nil
                         characters:text charactersIgnoringModifiers:text
                          isARepeat:phase == 2 keyCode:key];
}

static void verify_repeat(TelarTextInputView *view, unsigned short key, NSString *text, NSEventModifierFlags mods, telar_gui_input expected) {
    checking_repeat = true;
    expected_repeat = expected;
    expected_repeat.physical = key + 1;
    const int start = repeat_inputs;
    for (uint32_t phase = 1; phase <= 3; phase++) {
        expected_repeat.phase = phase;
        if (phase == 3) {
            if (expected_repeat.kind == 1) {
                expected_repeat.kind = 4;
                expected_repeat.code = [text characterAtIndex:0];
                expected_repeat.text = NULL;
                expected_repeat.len = 0;
            }
            [view keyUp:key_event(view, key, text, mods, phase)];
        } else {
            [view keyDown:key_event(view, key, text, mods, phase)];
            if (phase == 2) [view keyDown:key_event(view, key, text, mods, phase)];
        }
    }
    if (repeat_inputs != start + 4) failed++;
    checking_repeat = false;
}

static void verify_keyboard(TelarTextInputView *view) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"ApplePressAndHoldEnabled"]) failed++;
    verify_repeat(view, 38, @"j", 0, (telar_gui_input){.kind = 1, .text = (const uint8_t *)"j", .len = 1});
    verify_repeat(view, 38, @"J", NSEventModifierFlagShift, (telar_gui_input){.kind = 1, .text = (const uint8_t *)"J", .len = 1});
    verify_repeat(view, 125, @"\uf701", 0, (telar_gui_input){.kind = 3, .code = 6});
    verify_repeat(view, 51, @"\177", 0, (telar_gui_input){.kind = 3, .code = 3});
    verify_repeat(view, 38, @"j", NSEventModifierFlagControl, (telar_gui_input){.kind = 4, .code = 'j', .mods = 4});
    verify_repeat(view, 38, @"j", NSEventModifierFlagOption, (telar_gui_input){.kind = 4, .code = 'j', .mods = 2});

    // A later IME commit must not inherit the phase or identity of a held key.
    [view keyDown:key_event(view, 38, @"j", 0, 1)];
    [view keyDown:key_event(view, 38, @"j", 0, 2)];
    expected_repeat = (telar_gui_input){.kind = 1, .phase = 1, .text = (const uint8_t *)"caf\xc3\xa9", .len = 5};
    checking_repeat = true;
    const int before_commit = repeat_inputs;
    [view insertText:@"café" replacementRange:NSMakeRange(NSNotFound, 0)];
    if (repeat_inputs != before_commit + 1) failed++;

    expected_repeat = (telar_gui_input){.kind = 4, .phase = 3, .physical = 39, .code = 'j'};
    const int before_release = repeat_inputs;
    [view releasePressedKeys];
    [view releasePressedKeys];
    [view keyUp:key_event(view, 38, @"j", 0, 3)];
    if (repeat_inputs != before_release + 1) failed++;
    checking_repeat = false;
}

@interface NSView (TelarTest)
- (void)requestDraw;
- (void)pumpEvents;
@end

static NSEvent *pointer_event(NSView *view, NSEventType type, NSEventModifierFlags mods) {
    NSPoint point = NSMakePoint(13, 17);
    if (type == NSEventTypeFlagsChanged) {
        // Modifier events have no useful pointer coordinates.
        return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:mods timestamp:0
                           windowNumber:view.window.windowNumber context:nil characters:@""
             charactersIgnoringModifiers:@"" isARepeat:NO keyCode:55];
    }
    if (type == NSEventTypeMouseEntered || type == NSEventTypeMouseExited || type == NSEventTypeCursorUpdate) {
        return [NSEvent enterExitEventWithType:type location:point modifierFlags:mods timestamp:0
                                 windowNumber:view.window.windowNumber context:nil eventNumber:1
                               trackingNumber:0 userData:NULL];
    }
    return [NSEvent mouseEventWithType:type location:point modifierFlags:mods timestamp:0
                         windowNumber:view.window.windowNumber context:nil eventNumber:1
                           clickCount:0 pressure:0];
}

static void verify_pointer(TelarView *view) {
    for (uint32_t shape = 0; shape < 34; shape++) {
        NSCursor *cursor = telar_pointer_cursor(shape);
        if (cursor == nil || cursor != telar_pointer_cursor(shape)) failed++;
    }
    if (telar_pointer_cursor(2) != NSCursor.arrowCursor ||
        telar_pointer_cursor(4) != NSCursor.arrowCursor ||
        telar_pointer_cursor(5) != NSCursor.arrowCursor ||
        telar_pointer_cursor(UINT32_MAX) != NSCursor.arrowCursor ||
        telar_pointer_cursor(3) != NSCursor.pointingHandCursor ||
        telar_pointer_cursor(8) != NSCursor.IBeamCursor ||
        telar_pointer_cursor(14) != NSCursor.operationNotAllowedCursor ||
        telar_pointer_cursor(32) != NSCursor.zoomInCursor) failed++;

    checking_pointer = YES;
    expected_pointer = (telar_gui_input){.kind = 6, .code = 6, .phase = 1, .x = pointer_x, .y = pointer_y};
    [view mouseEntered:pointer_event(view, NSEventTypeMouseEntered, 0)];
    if (NSCursor.currentCursor != NSCursor.arrowCursor) failed++;

    // State changes refresh the native pointer before another GPU frame exists.
    const int before_pump = paints;
    const unsigned before_queries = pointer_queries;
    pointer_shape = 3;
    [view pumpEvents];
    if (paints != before_pump || pointer_queries <= before_queries ||
        NSCursor.currentCursor != NSCursor.pointingHandCursor) failed++;

    expected_pointer.mods = 15;
    [view mouseMoved:pointer_event(view, NSEventTypeMouseMoved,
        NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagControl | NSEventModifierFlagCommand)];
    expected_pointer.mods = 8;
    [view flagsChanged:pointer_event(view, NSEventTypeFlagsChanged, NSEventModifierFlagCommand)];
    expected_pointer.mods = 0;
    [view flagsChanged:pointer_event(view, NSEventTypeFlagsChanged, 0)];

    pointer_shape = 8;
    [view mouseMoved:pointer_event(view, NSEventTypeMouseMoved, 0)];
    if (NSCursor.currentCursor != NSCursor.IBeamCursor) failed++;
    [NSCursor.arrowCursor set];
    [view cursorUpdate:pointer_event(view, NSEventTypeCursorUpdate, 0)];
    if (NSCursor.currentCursor != NSCursor.IBeamCursor) failed++;

    expected_pointer.code = 7;
    [view mouseExited:pointer_event(view, NSEventTypeMouseExited, 0)];
    if (NSCursor.currentCursor != NSCursor.arrowCursor) failed++;
    const unsigned after_exit = pointer_inputs;
    [view flagsChanged:pointer_event(view, NSEventTypeFlagsChanged, NSEventModifierFlagCommand)];
    [view pumpEvents];
    if (pointer_inputs != after_exit || NSCursor.currentCursor != NSCursor.arrowCursor) failed++;

    expected_pointer.code = 6;
    [view mouseEntered:pointer_event(view, NSEventTypeMouseEntered, 0)];
    expected_pointer.code = 7;
    [view windowDidResignKey:[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:view.window]];
    if (NSCursor.currentCursor != NSCursor.arrowCursor) failed++;
    const unsigned after_focus = pointer_inputs;
    [view flagsChanged:pointer_event(view, NSEventTypeFlagsChanged, 0)];
    if (pointer_inputs != after_focus || pointer_inputs != 8) failed++;
    checking_pointer = NO;
    pointer_shape = 0;
}

static void draw(id view, SEL selector, id drawable) {
    NSWindow *window = [view window];
    NSRect outer_frame = window.frame;
    NSResponder *responder = window.firstResponder;
    BOOL was_key = window.isKeyWindow;
    int discarded_before = discarded;
    ((void (*)(id, SEL, id))original_draw)(view, selector, drawable);
    if (paints > 0) {
        BOOL opaque = appearance_phase == 2;
        uint32_t radius = appearance_phase == 0 ? 40 : appearance_phase == 1 || appearance_phase == 4 ? 80 : 0;
        NSVisualEffectView *effect = (NSVisualEffectView *)window.contentView.subviews.firstObject;
        BOOL titlebar = appearance_phase != 1 && appearance_phase != 4;
        if (window.isOpaque != opaque || ((NSView *)view).layer.isOpaque != opaque ||
            ![effect isKindOfClass:NSVisualEffectView.class] || !effect.isHidden ||
            ((TelarWindowBackground *)window.contentView).appliedBlurRadius != radius ||
            (!fullscreen_in_progress && (window.titleVisibility != (titlebar ? NSWindowTitleVisible : NSWindowTitleHidden) ||
            !!(window.styleMask & NSWindowStyleMaskFullSizeContentView) == titlebar ||
            [window standardWindowButton:NSWindowCloseButton].isHidden == titlebar)) ||
            !NSEqualRects(outer_frame, window.frame) ||
            (was_key && (!window.isKeyWindow || window.firstResponder != responder)) ||
            window.alphaValue != 1.0) failed++;
        if (!titlebar && !fullscreen_in_progress) {
            NSView *terminal = view;
            NSPoint top = NSMakePoint(NSMidX(terminal.bounds), terminal.bounds.size.height - 8);
            NSView *frame_view = window.contentView.superview;
            NSView *hit = [frame_view hitTest:[terminal convertPoint:top toView:frame_view]];
            if (hit != terminal && ![hit isDescendantOf:terminal]) failed++;
        }
        appearance_checked |= 1u << appearance_phase;
    }
    if (close_in_flight && discarded_before == discarded) {
        closed_in_flight = YES;
        [[view window] close];
    }
}
static const uint8_t pixels[] = {255,255,255,255};
// A plain quad, a rounded card and an inner ring exercise every fragment path.
static const telar_gui_quad quads[3] = {
    {20,20,200,100,0,0,1,1,0,1,0,1},
    {40,140,200,100,0,0,1,1,.2f,.4f,.9f,1,8,0,0,0,0,0,0,0},
    {60,260,200,100,0,0,1,1,0,0,0,0,8,2,0,0,1,.8f,.2f,1},
};
static void render(void *context, telar_gui_viewport viewport, telar_gui_frame *frame) {
    (void)context;
    if (!deferred) {
        deferred++;
        *frame = (telar_gui_frame){0};
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC * 10), dispatch_get_main_queue(), ^{
            [(id)terminal_view(NSApp.windows.firstObject.contentView) requestDraw];
        });
        return;
    }
    if (!viewport.width || !viewport.height) failed++;
    CAMetalLayer *layer = (CAMetalLayer *)terminal_view(NSApp.windows.firstObject.contentView).layer;
    if (layer && (viewport.width != (uint32_t)layer.drawableSize.width ||
                  viewport.height != (uint32_t)layer.drawableSize.height)) failed++;
    *frame = (telar_gui_frame){.token = ++paints, .quads = quads, .quad_count = 3, .atlas = pixels, .atlas_side = 2, .atlas_version = 1, .background = {.2f,.3f,.4f,appearance_phase == 2 ? 1 : .5f}, .background_blur = appearance_phase == 0 ? 40 : appearance_phase == 1 || appearance_phase == 4 ? 80 : 0, .titlebar = appearance_phase != 1 && appearance_phase != 4};
}
static int pump(void *context) {
    (void)context;
    if (deadline && CACurrentMediaTime() >= deadline) {
        deadline = 0;
        timer_wakes++;
        return 1;
    }
    return 0;
}
static uint32_t wakeup_after(void *context) {
    (void)context;
    return deadline ? (uint32_t)fmax(1, ceil((deadline - CACurrentMediaTime()) * 1000)) : 0;
}
static uint32_t desired_pointer(void *context) {
    (void)context;
    pointer_queries++;
    return pointer_shape;
}
static void complete(void *context, uint64_t token, int success) {
    (void)context;
    if (token != (uint64_t)delivered + discarded + 1) failed++;
    if (success) delivered++; else discarded++;
    if (delivered == 1 && success) deadline = CACurrentMediaTime() + 0.15;
    if (success && appearance_phase == 4 && !fullscreen_exit_scheduled) {
        fullscreen_exit_scheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(), ^{
            TelarWindow *window = (TelarWindow *)NSApp.windows.firstObject;
            if (!(window.styleMask & NSWindowStyleMaskFullScreen) || window.titlebarVisible) failed++;
            [window toggleFullScreen:nil];
        });
    }
}
static int input(void *context, telar_gui_input event) {
    (void)context;
    if (event.kind == 5) { focus_events++; return 1; }
    if (checking_pointer) {
        if (event.kind != expected_pointer.kind || event.code != expected_pointer.code ||
            event.mods != expected_pointer.mods || event.phase != expected_pointer.phase ||
            event.button != expected_pointer.button || event.x != expected_pointer.x ||
            event.y != expected_pointer.y || event.physical != 0) failed++;
        pointer_inputs++;
        return 1;
    }
    if (checking_repeat) {
        if (event.kind != expected_repeat.kind || event.phase != expected_repeat.phase ||
            event.physical != expected_repeat.physical || event.mods != expected_repeat.mods ||
            event.code != expected_repeat.code || event.len != expected_repeat.len ||
            (event.len && memcmp(event.text, expected_repeat.text, event.len))) failed++;
        repeat_inputs++;
        return 1;
    }
    if (!injecting) return 1;
    if (inputs == 0 && !(event.kind == 1 && event.len == 1 && event.text[0] == 'a' && event.physical == 1)) failed++;
    if (inputs == 1 && !(event.kind == 4 && event.code == 'c' && (event.mods & 4))) failed++;
    if (inputs == 2 && !(event.kind == 3 && event.code == 1)) failed++;
    if (inputs == 3 && !(event.kind == 1 && event.len == 5 && !memcmp(event.text,"caf\xc3\xa9",5))) failed++;
    if (inputs == 4 && !(event.kind == 4 && event.code == 'a' && event.phase == 3 && event.physical == 1)) failed++;
    if (inputs == 5 && !(event.kind == 4 && event.code == ' ' && event.mods == 4 && event.physical == 50 && event.phase == 1)) failed++;
    if (inputs == 6 && !(event.kind == 4 && event.code == ' ' && event.mods == 4 && event.physical == 50 && event.phase == 3)) failed++;
    if (inputs >= 7 && inputs <= 9) {
        uint32_t code = inputs == 7 ? 1 : inputs == 8 ? 3 : 2;
        if (event.kind != 6 || event.code != code || event.button != 0 ||
            event.x != pointer_x || event.y != pointer_y) failed++;
    }
    inputs++;
    return 1;
}
int main(void) {
    @autoreleasepool {
        // Simulate a user's global accent preference without changing disk state.
        [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"ApplePressAndHoldEnabled": @YES}
                                                       forName:NSGlobalDomain];
        Method method = class_getInstanceMethod(objc_getClass("TelarView"), @selector(drawWithDrawable:));
        original_draw = method_setImplementation(method, (IMP)draw);
        int fds[2];
        if (telar_gui_pipe(fds)) return 2;
        telar_gui_callbacks callbacks = {render,pump,complete,input,fds[0],wakeup_after,desired_pointer};
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        id entered = [center addObserverForName:NSWindowDidEnterFullScreenNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            NSWindow *window = note.object;
            if (!(window.styleMask & NSWindowStyleMaskFullScreen) || !window.isKeyWindow || window.firstResponder != terminal_view(window.contentView)) failed++;
            fullscreen_checked |= 1;
            appearance_phase = 4;
            [(id)terminal_view(window.contentView) requestDraw];
        }];
        id exited = [center addObserverForName:NSWindowDidExitFullScreenNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            TelarWindow *window = note.object;
            dispatch_async(dispatch_get_main_queue(), ^{
                fullscreen_in_progress = NO;
                if ((window.styleMask & NSWindowStyleMaskFullScreen) || window.titlebarVisible ||
                    !(window.styleMask & NSWindowStyleMaskFullSizeContentView) ||
                    !window.isKeyWindow || window.firstResponder != terminal_view(window.contentView)) failed++;
                fullscreen_checked |= 2;
                appearance_phase = 3;
                close_in_flight = YES;
                [(id)terminal_view(window.contentView) requestDraw];
            });
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1000000000), dispatch_get_main_queue(), ^{
            NSWindow *window = NSApp.windows.firstObject;
            NSView *view = terminal_view(window.contentView);
            if (timer_wakes != 1 || delivered < 2 || !focus_events) failed++;
            injecting = YES;
            [view keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil characters:@"a" charactersIgnoringModifiers:@"a" isARepeat:NO keyCode:0]];
            [view keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagControl timestamp:0 windowNumber:window.windowNumber context:nil characters:@"\003" charactersIgnoringModifiers:@"c" isARepeat:NO keyCode:8]];
            [view keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36]];
            [(id<NSTextInputClient>)view insertText:@"café" replacementRange:NSMakeRange(NSNotFound,0)];
            [view keyUp:[NSEvent keyEventWithType:NSEventTypeKeyUp location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil characters:@"a" charactersIgnoringModifiers:@"a" isARepeat:NO keyCode:0]];
            [view keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagControl timestamp:0 windowNumber:window.windowNumber context:nil characters:@"\0" charactersIgnoringModifiers:@" " isARepeat:NO keyCode:49]];
            [view keyUp:[NSEvent keyEventWithType:NSEventTypeKeyUp location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil characters:@" " charactersIgnoringModifiers:@" " isARepeat:NO keyCode:49]];
            NSPoint location = NSMakePoint(13, 17);
            NSPoint local = [view convertPoint:location fromView:nil];
            pointer_x = local.x * window.backingScaleFactor;
            pointer_y = (view.isFlipped ? local.y : view.bounds.size.height - local.y) * window.backingScaleFactor;
            [view mouseDown:[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:location modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1]];
            [view mouseDragged:[NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged location:location modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil eventNumber:2 clickCount:1 pressure:1]];
            [view mouseUp:[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:location modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil eventNumber:3 clickCount:1 pressure:0]];
            injecting = NO;
            [(TelarTextInputView *)view releasePressedKeys];
            verify_keyboard((TelarTextInputView *)view);
            verify_pointer((TelarView *)view);
            appearance_phase = 1;
            [window setContentSize:NSMakeSize(640, 360)];
            int burst_start = paints;
            for (int i = 0; i < 100; i++) [view requestDraw];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (paints - burst_start > 3) failed++;
                int idle_paints = paints;
                if (paints != delivered + discarded) failed++;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 3), dispatch_get_main_queue(), ^{
                    if (paints != idle_paints) failed++;
                    appearance_phase = 2;
                    [view requestDraw];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 3), dispatch_get_main_queue(), ^{
                        fullscreen_in_progress = YES;
                        [window toggleFullScreen:nil];
                    });
                });
            });
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (!closed_in_flight) {
                fprintf(stderr, "Native fullscreen lifecycle timed out\n");
                failed++;
                [NSApp.windows.firstObject close];
            }
        });
        int status = telar_gui_run("Telar native backend test", NULL, &callbacks);
        [center removeObserver:entered];
        [center removeObserver:exited];
        telar_gui_close_pipe(fds);
        fprintf(stdout, "native macOS: status=%d painted=%d delivered=%d discarded=%d inputs=%d repeats=%d pointer_inputs=%u pointer_queries=%u timer_wakes=%d fullscreen=%u failures=%d\n",status,paints,delivered,discarded,inputs,repeat_inputs,pointer_inputs,pointer_queries,timer_wakes,fullscreen_checked,failed);
        return status || !delivered || inputs != 10 || repeat_inputs != 26 || pointer_inputs != 8 || failed || !closed_in_flight || paints != delivered + discarded + 1 || discarded < 2 || appearance_checked != 31 || fullscreen_checked != 3;
    }
}
