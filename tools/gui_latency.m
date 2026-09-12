// Test-only AppKit injector. Wraps the existing frame contract, never production
// input policy. Each next key waits for the expected glyph count's GPU token.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <crt_externs.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../src/gui/native/telar_gui.h"

static telar_gui_callbacks original;
static IMP original_init;
static uint64_t matching_token;
static size_t glyph_count, baseline;
static telar_gui_viewport measured_viewport;
static BOOL started, pending;
static int count, limit;
static double start_time, gap;
static double samples[512];

static void finish(int failed) {
    FILE *file = fopen(getenv("TELAR_GUI_PROBE_RESULT"), "w");
    if (file) {
        fprintf(file, "{\"failed\":%d,\"baseline_glyphs\":%zu,\"viewport\":[%u,%u,%.1f],\"samples_ms\":[", failed, baseline, measured_viewport.width, measured_viewport.height, measured_viewport.scale);
        for (int i = 0; i < count; i++) fprintf(file, "%s%.6f", i ? "," : "", samples[i]);
        fprintf(file, "]}\n");
        fclose(file);
    }
    [NSApp.keyWindow close];
}

static void send_key(void) {
    if (count == limit) { finish(0); return; }
    NSWindow *window = NSApp.keyWindow;
    if (window == nil) { finish(1); return; }
    BOOL erase = count & 1;
    NSString *text = erase ? @"\177" : @"x";
    pending = YES;
    matching_token = 0;
    start_time = CACurrentMediaTime();
    [window.contentView keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown
        location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:window.windowNumber
        context:nil characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:erase ? 51 : 7]];
}

static void render(void *context, telar_gui_viewport viewport, telar_gui_frame *frame) {
    measured_viewport = viewport;
    original.render(context, viewport, frame);
    glyph_count = 0;
    for (size_t i = 0; i < frame->quad_count; i++) {
        const telar_gui_quad *q = &frame->quads[i];
        if (q->u0 != q->u1 && q->v0 != q->v1) glyph_count++;
    }
    if (pending && glyph_count == baseline + ((count & 1) ? 0 : 1)) matching_token = frame->token;
}

static void complete(void *context, uint64_t token, int success) {
    double completed = CACurrentMediaTime();
    original.complete(context, token, success);
    if (!success || !token) return;
    if (!started) {
        started = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            baseline = glyph_count;
            send_key();
        });
    } else if (pending && token == matching_token) {
        samples[count++] = (completed - start_time) * 1000;
        pending = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gap * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ send_key(); });
    }
}

static id initialize(id self, SEL selector, NSRect frame, void *context, const telar_gui_callbacks *callbacks) {
    original = *callbacks;
    telar_gui_callbacks wrapped = *callbacks;
    wrapped.render = render;
    wrapped.complete = complete;
    return ((id (*)(id, SEL, NSRect, void *, const telar_gui_callbacks *))original_init)(self, selector, frame, context, &wrapped);
}

__attribute__((constructor)) static void install(void) {
    char **argv = *_NSGetArgv();
    if (*_NSGetArgc() < 2 || strcmp(argv[1], "gui")) return;
    limit = atoi(getenv("TELAR_GUI_PROBE_SAMPLES"));
    gap = atof(getenv("TELAR_GUI_PROBE_GAP"));
    if (limit < 1 || limit > 512) abort();
    Method method = class_getInstanceMethod(objc_getClass("TelarView"), sel_registerName("initWithFrame:context:callbacks:"));
    if (!method) abort();
    original_init = method_setImplementation(method, (IMP)initialize);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ finish(1); });
}
