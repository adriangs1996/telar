#pragma once
#include <stdbool.h>
#include <wayland-client.h>

// One compositor callback per submitted frame and a 60 Hz submission budget.
typedef struct {
    struct wl_callback *callback;
    int64_t next_draw_ns;
} telar_frame_clock;

// Remaining deadline for a dirty window; -1 waits for the compositor.
int telar_frame_clock_timeout(const telar_frame_clock *self);
bool telar_frame_clock_ready(const telar_frame_clock *self);
// Arm before the worker commits the surface via vkQueuePresentKHR.
bool telar_frame_clock_request(telar_frame_clock *self, struct wl_surface *surface);
// Cancel an uncommitted request on retry, or disconnect on window close.
void telar_frame_clock_cancel(telar_frame_clock *self);
