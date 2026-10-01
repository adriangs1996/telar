// Test-only AppKit injector for gui_frame_rate.py. Wraps the frame contract,
// never production pacing: counts delivered presentations while a pane floods,
// with the interval the window reported and paced at. Older builds without
// the display interval callbacks build with TELAR_GUI_RATE_LEGACY against
// their own telar_gui.h.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <crt_externs.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "telar_gui.h"

enum { sample_capacity = 65536 };

static telar_gui_callbacks original;
static IMP original_init;
static __weak NSView *probe_view;
static BOOL measuring, done;
static double measure_start, last_presented, rendered_at;
static uint64_t rendered_token, reported_display_ns, frame_interval_ns;
static double gaps[sample_capacity], flight[sample_capacity];
static int presented, gap_count, flight_count;
static double seconds = 6, warmup = 5;

static int compare(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static double percentile(double *values, int count, int percent) {
    if (count == 0) return 0;
    qsort(values, count, sizeof *values, compare);
    return values[count * percent / 100];
}

static void finish(void) {
    if (done) return;
    done = YES;
    double elapsed = CACurrentMediaTime() - measure_start;
    NSScreen *screen = probe_view.window.screen;
    FILE *file = fopen(getenv("TELAR_GUI_RATE_RESULT"), "w");
    if (file) {
        fprintf(file,
                "{\"screen\":\"%s\",\"screen_max_fps\":%ld,\"display_interval_ns\":%llu,\"frame_interval_ns\":%llu,"
                "\"presented\":%d,\"seconds\":%.3f,\"presented_per_second\":%.2f,\"gap_p50_ms\":%.3f,"
                "\"render_to_complete_p50_ms\":%.3f,\"render_to_complete_p95_ms\":%.3f}\n",
                screen.localizedName.UTF8String, (long)screen.maximumFramesPerSecond,
                (unsigned long long)reported_display_ns, (unsigned long long)frame_interval_ns, presented, elapsed,
                elapsed > 0 ? presented / elapsed : 0, percentile(gaps, gap_count, 50),
                percentile(flight, flight_count, 50), percentile(flight, flight_count, 95));
        fclose(file);
    }
    [probe_view.window close];
}

static void render(void *context, telar_gui_viewport viewport, telar_gui_frame *frame) {
    original.render(context, viewport, frame);
    rendered_at = CACurrentMediaTime();
    rendered_token = frame->token;
}

static void complete(void *context, uint64_t token, int success) {
    original.complete(context, token, success);
    if (!success || !token || !measuring || done) return;
    double now = CACurrentMediaTime();
    if (token == rendered_token && flight_count < sample_capacity) flight[flight_count++] = (now - rendered_at) * 1000;
    if (presented > 0 && gap_count < sample_capacity) gaps[gap_count++] = (now - last_presented) * 1000;
    last_presented = now;
    presented++;
}

#ifndef TELAR_GUI_RATE_LEGACY
static void display_interval(void *context, uint64_t interval_ns) {
    reported_display_ns = interval_ns;
    if (original.display_interval) original.display_interval(context, interval_ns);
}

static uint64_t frame_interval(void *context) {
    frame_interval_ns = original.frame_interval_ns ? original.frame_interval_ns(context) : 0;
    return frame_interval_ns;
}
#endif

static id initialize(id self, SEL selector, NSRect frame, void *context, const telar_gui_callbacks *callbacks) {
    original = *callbacks;
    telar_gui_callbacks wrapped = *callbacks;
    wrapped.render = render;
    wrapped.complete = complete;
#ifndef TELAR_GUI_RATE_LEGACY
    wrapped.display_interval = display_interval;
    wrapped.frame_interval_ns = frame_interval;
#endif
    id view = ((id (*)(id, SEL, NSRect, void *, const telar_gui_callbacks *))original_init)(self, selector, frame, context, &wrapped);
    probe_view = view;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(warmup * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        measuring = YES;
        measure_start = CACurrentMediaTime();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ finish(); });
    });
    return view;
}

__attribute__((constructor)) static void install(void) {
    char **argv = *_NSGetArgv();
    if (*_NSGetArgc() < 2 || strcmp(argv[1], "gui")) return;
    if (getenv("TELAR_GUI_RATE_SECONDS")) seconds = atof(getenv("TELAR_GUI_RATE_SECONDS"));
    if (getenv("TELAR_GUI_RATE_WARMUP")) warmup = atof(getenv("TELAR_GUI_RATE_WARMUP"));
    Method method = class_getInstanceMethod(objc_getClass("TelarView"), sel_registerName("initWithFrame:context:callbacks:"));
    if (!method) abort();
    original_init = method_setImplementation(method, (IMP)initialize);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((warmup + seconds + 30) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ finish(); });
}
