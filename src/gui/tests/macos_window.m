#include "../../../tools/gui_view.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#include "telar_gui.h"
#include <stdio.h>
#include <string.h>
#include <math.h>

static int paints, delivered, inputs, failed;
static BOOL injecting, close_in_flight, closed_in_flight;
static IMP original_draw;
static CFTimeInterval deadline;
static int timer_wakes, focus_events;
static int deferred;
static unsigned appearance_phase;
static unsigned appearance_checked;

@interface NSView (TelarTest)
- (void)requestDraw;
@end

static void draw(id view, SEL selector, id drawable) {
    ((void (*)(id, SEL, id))original_draw)(view, selector, drawable);
    if (paints > 0) {
        BOOL opaque = appearance_phase == 1;
        BOOL blurred = appearance_phase == 0;
        NSWindow *window = [view window];
        NSVisualEffectView *effect = (NSVisualEffectView *)window.contentView.subviews.firstObject;
        if (window.isOpaque != opaque || ((NSView *)view).layer.isOpaque != opaque ||
            ![effect isKindOfClass:NSVisualEffectView.class] || effect.isHidden == blurred ||
            window.alphaValue != 1.0) failed++;
        appearance_checked |= 1u << appearance_phase;
    }
    if (close_in_flight) {
        closed_in_flight = YES;
        [[view window] close];
    }
}
static const uint8_t pixels[] = {255,255,255,255};
static const telar_gui_quad quad = {20,20,200,100,0,0,1,1,0,1,0,1};
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
    *frame = (telar_gui_frame){.token = ++paints, .quads = &quad, .quad_count = 1, .atlas = pixels, .atlas_side = 2, .atlas_version = 1, .background = {.2f,.3f,.4f,appearance_phase == 1 ? 1 : .5f}, .background_blur = appearance_phase != 2};
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
static void complete(void *context, uint64_t token, int success) {
    (void)context;
    if (token == (uint64_t)delivered + 1 && success) delivered++; else failed++;
    if (delivered == 1) deadline = CACurrentMediaTime() + 0.15;
}
static int input(void *context, telar_gui_input event) {
    (void)context;
    if (event.kind == 5) { focus_events++; return 1; }
    if (!injecting) return 1;
    if (inputs == 0 && !(event.kind == 1 && event.len == 1 && event.text[0] == 'a')) failed++;
    if (inputs == 1 && !(event.kind == 4 && event.code == 'c' && (event.mods & 4))) failed++;
    if (inputs == 2 && !(event.kind == 3 && event.code == 1)) failed++;
    if (inputs == 3 && !(event.kind == 1 && event.len == 5 && !memcmp(event.text,"caf\xc3\xa9",5))) failed++;
    inputs++;
    return 1;
}
int main(void) {
    @autoreleasepool {
        Method method = class_getInstanceMethod(objc_getClass("TelarView"), @selector(drawWithDrawable:));
        original_draw = method_setImplementation(method, (IMP)draw);
        int fds[2];
        if (telar_gui_pipe(fds)) return 2;
        telar_gui_callbacks callbacks = {render,pump,complete,input,fds[0],wakeup_after};
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1000000000), dispatch_get_main_queue(), ^{
            NSWindow *window = NSApp.windows.firstObject;
            NSView *view = terminal_view(window.contentView);
            if (timer_wakes != 1 || delivered < 2 || !focus_events) failed++;
            injecting = YES;
            [view keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil characters:@"a" charactersIgnoringModifiers:@"a" isARepeat:NO keyCode:0]];
            [view keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagControl timestamp:0 windowNumber:window.windowNumber context:nil characters:@"\003" charactersIgnoringModifiers:@"c" isARepeat:NO keyCode:8]];
            [view keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36]];
            [(id<NSTextInputClient>)view insertText:@"café" replacementRange:NSMakeRange(NSNotFound,0)];
            injecting = NO;
            appearance_phase = 1;
            view.autoresizingMask = NSViewNotSizable;
            [view setFrameSize:NSMakeSize(640, 360)];
            int burst_start = paints;
            for (int i = 0; i < 100; i++) [view requestDraw];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (paints - burst_start > 2) failed++;
                int idle_paints = paints;
                if (paints != delivered) failed++;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 3), dispatch_get_main_queue(), ^{
                    if (paints != idle_paints) failed++;
                    appearance_phase = 2;
                    close_in_flight = YES;
                    [view requestDraw];
                });
            });
        });
        int status = telar_gui_run("Telar native backend test", NULL, &callbacks);
        telar_gui_close_pipe(fds);
        fprintf(stdout, "native macOS: status=%d painted=%d delivered=%d inputs=%d timer_wakes=%d failures=%d\n",status,paints,delivered,inputs,timer_wakes,failed);
        return status || !delivered || inputs != 4 || failed || !closed_in_flight || paints != delivered + 1 || appearance_checked != 7;
    }
}
