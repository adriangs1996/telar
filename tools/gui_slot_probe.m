// Test-only, bounded tracing of native scheduling and Metal submission.
// Example: DYLD_INSERT_LIBRARIES=probe.dylib TELAR_SLOT_TRACE=trace.json telar gui.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../src/gui/native/telar_gui.h"

enum EventKind {
    MeasureStart, RequestBegin, RequestEnd, ReadyBegin, ReadyEnd,
    DrawableBegin, DrawableEnd, DrawBegin, DrawEnd, PrepareBegin, PrepareEnd,
    EncodeBegin, EncodeEnd, WaitBegin, WaitEnd, CommitBegin, CommitEnd,
    GPUComplete, GPUStart, GPUEnd, CompleteBegin, CompleteEnd,
    PumpBegin, PumpEnd, InputBegin, InputEnd, CloseBegin, CloseEnd, FrameMarker,
};

static const char *event_names[] = {
    "measure_start", "request_begin", "request_end", "ready_begin", "ready_end",
    "drawable_begin", "drawable_end", "draw_begin", "draw_end", "prepare_begin", "prepare_end",
    "encode_begin", "encode_end", "wait_begin", "wait_end", "commit_begin", "commit_end",
    "gpu_complete", "gpu_start", "gpu_end", "complete_begin", "complete_end",
    "pump_begin", "pump_end", "input_begin", "input_end", "close_begin", "close_end", "frame_marker",
};

enum { HasState = 1, Dirty = 2, Busy = 4, Visible = 8, Closed = 16 };
enum { EventCapacity = 262144 };
typedef struct {
    double at, value;
    uint64_t token;
    uint32_t kind, flags;
} TraceEvent;

static TraceEvent events[EventCapacity];
static atomic_uint event_count;
static atomic_bool recording;
static atomic_ullong active_token;
static BOOL dumped;
static BOOL trace_marker;
static const char *trace_path;
static uint32_t viewport_width, viewport_height;
static telar_gui_callbacks original_callbacks;
static IMP original_init, original_request, original_ready, original_draw;
static IMP original_next, original_encode, original_submission, original_wait;
static IMP original_commit, original_close;
static Ivar renderer_ivar, dirty_ivar, closed_ivar, deadline_ivar, feedback_ivar;

// Reservations are bounded; GPU feedback writes its record before the native
// completion releases its dispatch group. Closing the window joins that group.
static TraceEvent *record(enum EventKind kind, uint64_t token, double value) {
    if (!atomic_load_explicit(&recording, memory_order_relaxed)) {
        return NULL;
    }
    unsigned index = atomic_fetch_add_explicit(&event_count, 1, memory_order_relaxed);
    if (index >= EventCapacity) {
        return NULL;
    }
    TraceEvent *event = &events[index];
    event->at = CACurrentMediaTime();
    event->kind = kind;
    event->token = token;
    event->value = value;
    return event;
}

static void record_state(enum EventKind kind, NSView *view) {
    TraceEvent *event = record(kind, 0, 0);
    if (event == NULL) {
        return;
    }
    const char *storage = (__bridge const void *)view;
    BOOL dirty, closed;
    memcpy(&dirty, storage + ivar_getOffset(dirty_ivar), sizeof dirty);
    memcpy(&closed, storage + ivar_getOffset(closed_ivar), sizeof closed);
    memcpy(&event->value, storage + ivar_getOffset(deadline_ivar), sizeof event->value);
    id renderer = object_getIvar(view, renderer_ivar);
    BOOL busy = ((BOOL (*)(id, SEL))objc_msgSend)(renderer, @selector(isBusy));
    event->flags = HasState | (dirty ? Dirty : 0) | (busy ? Busy : 0) |
        ((view.window.occlusionState & NSWindowOcclusionStateVisible) ? Visible : 0) |
        (closed ? Closed : 0);
}

static void dump_trace(void) {
    if (dumped) {
        return;
    }
    dumped = YES;
    atomic_store_explicit(&recording, false, memory_order_relaxed);
    unsigned count = atomic_load_explicit(&event_count, memory_order_relaxed);
    FILE *file = fopen(trace_path, "w");
    if (file == NULL) {
        return;
    }
    fprintf(file, "{\"version\":1,\"capacity\":%u,\"dropped\":%u,\"viewport\":[%u,%u],\"events\":[\n",
            EventCapacity, count > EventCapacity ? count - EventCapacity : 0,
            viewport_width, viewport_height);
    count = MIN(count, EventCapacity);
    for (unsigned i = 0; i < count; i++) {
        TraceEvent *event = &events[i];
        fprintf(file, "%s[\"%s\",%.9f,%llu,%.9f,%u]",
                i ? ",\n" : "", event_names[event->kind], event->at,
                (unsigned long long)event->token, event->value, event->flags);
    }
    fprintf(file, "\n]}\n");
    fclose(file);
}

static void request_draw(id self, SEL selector) {
    record_state(RequestBegin, self);
    ((void (*)(id, SEL))original_request)(self, selector);
    record_state(RequestEnd, self);
}

static void draw_if_ready(id self, SEL selector) {
    record_state(ReadyBegin, self);
    ((void (*)(id, SEL))original_ready)(self, selector);
    record_state(ReadyEnd, self);
}

static void draw(id self, SEL selector, id drawable) {
    record_state(DrawBegin, self);
    ((void (*)(id, SEL, id))original_draw)(self, selector, drawable);
    record_state(DrawEnd, self);
}

static id next_drawable(id self, SEL selector) {
    record(DrawableBegin, 0, 0);
    id drawable = ((id (*)(id, SEL))original_next)(self, selector);
    record(DrawableEnd, 0, drawable != nil);
    return drawable;
}

static void prepare(void *context, telar_gui_viewport viewport, telar_gui_frame *frame) {
    record(PrepareBegin, 0, 0);
    original_callbacks.render(context, viewport, frame);
    viewport_width = viewport.width;
    viewport_height = viewport.height;
    record(PrepareEnd, frame->token, frame->quad_count);
    if (trace_marker) {
        for (uint32_t i = 0; i < frame->quad_count; i++) {
            const telar_gui_quad *quad = &frame->quads[i];
            if (quad->x == 0 && quad->y == 0 && (unsigned)(quad->r * 255 + .5f) == 128) {
                unsigned sequence = ((unsigned)(quad->g * 255 + .5f) << 8) | (unsigned)(quad->b * 255 + .5f);
                record(FrameMarker, frame->token, sequence);
                break;
            }
        }
    }
}

static int pump(void *context) {
    record(PumpBegin, 0, 0);
    int result = original_callbacks.pump(context);
    record(PumpEnd, 0, result);
    return result;
}

static void complete(void *context, uint64_t token, int success) {
    record(CompleteBegin, token, success);
    original_callbacks.complete(context, token, success);
    record(CompleteEnd, token, success);
}

static int input(void *context, telar_gui_input event) {
    record(InputBegin, 0, event.kind);
    int result = original_callbacks.input(context, event);
    record(InputEnd, 0, result);
    return result;
}

static id initialize(id self, SEL selector, NSRect frame, void *context,
                     const telar_gui_callbacks *callbacks) {
    original_callbacks = *callbacks;
    telar_gui_callbacks wrapped = *callbacks;
    wrapped.render = prepare;
    wrapped.pump = pump;
    wrapped.complete = complete;
    wrapped.input = input;
    return ((id (*)(id, SEL, NSRect, void *, const telar_gui_callbacks *))original_init)
        (self, selector, frame, context, &wrapped);
}

static BOOL encode(id self, SEL selector, const telar_gui_frame *frame, id drawable) {
    atomic_store_explicit(&active_token, frame->token, memory_order_relaxed);
    record(EncodeBegin, frame->token, frame->quad_count);
    BOOL result = ((BOOL (*)(id, SEL, const telar_gui_frame *, id))original_encode)
        (self, selector, frame, drawable);
    record(EncodeEnd, frame->token, result);
    return result;
}

static void wait_drawable(id self, SEL selector, id drawable) {
    uint64_t token = atomic_load_explicit(&active_token, memory_order_relaxed);
    record(WaitBegin, token, 0);
    ((void (*)(id, SEL, id))original_wait)(self, selector, drawable);
    record(WaitEnd, token, 0);
}

static void commit(id self, SEL selector, const id<MTL4CommandBuffer> *buffers,
                   NSUInteger count, MTL4CommitOptions *options) {
    uint64_t token = atomic_load_explicit(&active_token, memory_order_relaxed);
    record(CommitBegin, token, count);
    ((void (*)(id, SEL, const id<MTL4CommandBuffer> *, NSUInteger, id))original_commit)
        (self, selector, buffers, count, options);
    record(CommitEnd, token, count);
}

// One replacement block per renderer, re-armed by production for each commit.
// Record before the original handler to prevent a new main-thread submission
// from replacing active_token before this feedback has been associated.
static BOOL build_submission(id self, SEL selector) {
    BOOL result = ((BOOL (*)(id, SEL))original_submission)(self, selector);
    if (!result) {
        return NO;
    }
    MTL4CommitFeedbackHandler original = object_getIvar(self, feedback_ivar);
    MTL4CommitFeedbackHandler wrapped = ^(id<MTL4CommitFeedback> feedback) {
        uint64_t token = atomic_load_explicit(&active_token, memory_order_relaxed);
        record(GPUComplete, token, feedback.error == nil);
        record(GPUStart, token, feedback.GPUStartTime);
        record(GPUEnd, token, feedback.GPUEndTime);
        original(feedback);
    };
    object_setIvar(self, feedback_ivar, [wrapped copy]);
    return YES;
}

static void close_window(id self, SEL selector, id notification) {
    record_state(CloseBegin, self);
    ((void (*)(id, SEL, id))original_close)(self, selector, notification);
    record_state(CloseEnd, self);
    dump_trace();
}

static IMP hook(Class cls, const char *name, IMP replacement) {
    Method method = class_getInstanceMethod(cls, sel_registerName(name));
    if (method == NULL) {
        abort();
    }
    return method_setImplementation(method, replacement);
}

__attribute__((constructor)) static void install(void) {
    trace_path = getenv("TELAR_SLOT_TRACE");
    trace_marker = getenv("TELAR_SLOT_MARKER") != NULL;
    if (trace_path == NULL || ![NSProcessInfo.processInfo.arguments containsObject:@"gui"]) {
        return;
    }
    Class view = objc_getClass("TelarView");
    Class renderer = objc_getClass("TelarMetalRenderer");
    renderer_ivar = class_getInstanceVariable(view, "renderer");
    dirty_ivar = class_getInstanceVariable(view, "dirty");
    closed_ivar = class_getInstanceVariable(view, "closed");
    deadline_ivar = class_getInstanceVariable(view, "next_draw");
    feedback_ivar = class_getInstanceVariable(renderer, "feedback_handler");
    if (!renderer_ivar || !dirty_ivar || !closed_ivar || !deadline_ivar || !feedback_ivar) {
        abort();
    }
    original_init = hook(view, "initWithFrame:context:callbacks:", (IMP)initialize);
    original_request = hook(view, "requestDraw", (IMP)request_draw);
    original_ready = hook(view, "drawIfReady", (IMP)draw_if_ready);
    original_draw = hook(view, "drawWithDrawable:", (IMP)draw);
    original_close = hook(view, "windowWillClose:", (IMP)close_window);
    original_encode = hook(renderer, "renderFrame:drawable:", (IMP)encode);
    original_submission = hook(renderer, "buildSubmission", (IMP)build_submission);
    original_next = hook(CAMetalLayer.class, "nextDrawable", (IMP)next_drawable);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTL4CommandQueue> queue = [device newMTL4CommandQueue];
    original_wait = hook([queue class], "waitForDrawable:", (IMP)wait_drawable);
    original_commit = hook([queue class], "commit:count:options:", (IMP)commit);

    const char *viewport = getenv("TELAR_SLOT_VIEWPORT");
    if (viewport != NULL) {
        unsigned width, height;
        if (sscanf(viewport, "%u,%u", &width, &height) != 2 || !width || !height) {
            abort();
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSView *view = NSApp.windows.firstObject.contentView;
            CGFloat scale = view.window.backingScaleFactor;
            view.autoresizingMask = NSViewNotSizable;
            [view setFrameSize:NSMakeSize(width / scale, height / scale)];
        });
    }
    double delay = getenv("TELAR_SLOT_START") ? atof(getenv("TELAR_SLOT_START")) : 3;
    double duration = getenv("TELAR_SLOT_SECONDS") ? atof(getenv("TELAR_SLOT_SECONDS")) : 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        atomic_store_explicit(&recording, true, memory_order_relaxed);
        NSView *view = NSApp.windows.firstObject.contentView;
        if (view != nil) {
            record_state(MeasureStart, view);
        }
    });
    if (duration > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((delay + duration) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [NSApp.windows.firstObject close];
        });
    }
}
