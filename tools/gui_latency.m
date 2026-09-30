#include "gui_view.h"
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
static double start_time, gap, settle = 1;
static double samples[512];
// Per-frame prepare time (the render callback) and per-upload latency, from
// the frame that hands an upload over to its image_ready report.
enum { trace_capacity = 8192 };
static double prepare_ms[trace_capacity], upload_ms[trace_capacity];
static int prepare_count, upload_count;
static double upload_started[TELAR_GUI_IMAGE_CAPACITY + 1];

static void write_list(FILE *file, const char *name, const double *values, int count) {
    fprintf(file, ",\"%s\":[", name);
    for (int i = 0; i < count; i++) fprintf(file, "%s%.6f", i ? "," : "", values[i]);
    fprintf(file, "]");
}

static void finish(int failed) {
    FILE *file = fopen(getenv("TELAR_GUI_PROBE_RESULT"), "w");
    if (file) {
        fprintf(file, "{\"failed\":%d,\"baseline_glyphs\":%zu,\"viewport\":[%u,%u,%.1f],\"samples_ms\":[", failed, baseline, measured_viewport.width, measured_viewport.height, measured_viewport.scale);
        for (int i = 0; i < count; i++) fprintf(file, "%s%.6f", i ? "," : "", samples[i]);
        fprintf(file, "]");
        write_list(file, "prepare_ms", prepare_ms, prepare_count);
        write_list(file, "upload_ms", upload_ms, upload_count);
        fprintf(file, "}\n");
        fclose(file);
    }
    [NSApp.windows.firstObject close];
}

static void send_key(void) {
    if (count == limit) { finish(0); return; }
    NSWindow *window = NSApp.windows.firstObject;
    if (window == nil) { finish(1); return; }
    BOOL erase = count & 1;
    NSString *text = erase ? @"\177" : @"x";
    pending = YES;
    matching_token = 0;
    start_time = CACurrentMediaTime();
    [terminal_view(window.contentView) keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown
        location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:window.windowNumber
        context:nil characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:erase ? 51 : 7]];
}

static void render(void *context, telar_gui_viewport viewport, telar_gui_frame *frame) {
    measured_viewport = viewport;
    double started = CACurrentMediaTime();
    original.render(context, viewport, frame);
    double finished = CACurrentMediaTime();
    if (frame->token && prepare_count < trace_capacity) prepare_ms[prepare_count++] = (finished - started) * 1000;
    for (uint32_t i = 0; frame->image_uploads && i < frame->image_upload_count; i++) {
        uint32_t handle = frame->image_uploads[i].handle;
        if (handle >= 1 && handle <= TELAR_GUI_IMAGE_CAPACITY) upload_started[handle] = finished;
    }
    // Glyphs and other textured chrome; image quads (texture 10) are not
    // text, so a streamed image never changes the count the probe waits on.
    glyph_count = 0;
    for (size_t i = 0; i < frame->quad_count; i++) {
        const telar_gui_quad *q = &frame->quads[i];
        if (q->u0 != q->u1 && q->v0 != q->v1 && q->texture < TELAR_GUI_IMAGE_TEXTURE - 0.5f) glyph_count++;
    }
    if (getenv("GUI_PROBE_TRACE")) {
        size_t images = 0;
        for (size_t i = 0; i < frame->quad_count; i++) images += frame->quads[i].texture > 9.5f;
        fprintf(stderr, "probe frame t=%.4f token=%llu quads=%u glyphs=%zu images=%zu draws=%u pending=%d count=%d\n", CACurrentMediaTime(), (unsigned long long)frame->token, frame->quad_count, glyph_count, images, frame->image_draw_count, pending, count);
    }
    if (pending && glyph_count == baseline + ((count & 1) ? 0 : 1)) matching_token = frame->token;
}

static void complete(void *context, uint64_t token, int success) {
    double completed = CACurrentMediaTime();
    original.complete(context, token, success);
    if (!success || !token) return;
    if (!started) {
        started = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(settle * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            baseline = glyph_count;
            send_key();
        });
    } else if (pending && token == matching_token) {
        samples[count++] = (completed - start_time) * 1000;
        pending = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gap * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ send_key(); });
    }
}

static void image_ready(void *context, uint32_t handle, int success) {
    if (handle >= 1 && handle <= TELAR_GUI_IMAGE_CAPACITY && upload_started[handle] > 0 && success &&
        upload_count < trace_capacity) {
        upload_ms[upload_count++] = (CACurrentMediaTime() - upload_started[handle]) * 1000;
    }
    if (original.image_ready) original.image_ready(context, handle, success);
}

static id initialize(id self, SEL selector, NSRect frame, void *context, const telar_gui_callbacks *callbacks) {
    original = *callbacks;
    telar_gui_callbacks wrapped = *callbacks;
    wrapped.render = render;
    wrapped.complete = complete;
    wrapped.image_ready = image_ready;
    return ((id (*)(id, SEL, NSRect, void *, const telar_gui_callbacks *))original_init)(self, selector, frame, context, &wrapped);
}

__attribute__((constructor)) static void install(void) {
    char **argv = *_NSGetArgv();
    if (*_NSGetArgc() < 2 || strcmp(argv[1], "gui")) return;
    limit = atoi(getenv("TELAR_GUI_PROBE_SAMPLES"));
    gap = atof(getenv("TELAR_GUI_PROBE_GAP"));
    if (getenv("TELAR_GUI_PROBE_SETTLE")) settle = atof(getenv("TELAR_GUI_PROBE_SETTLE"));
    if (limit < 1 || limit > 512) abort();
    Method method = class_getInstanceMethod(objc_getClass("TelarView"), sel_registerName("initWithFrame:context:callbacks:"));
    if (!method) abort();
    original_init = method_setImplementation(method, (IMP)initialize);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ finish(1); });
}
