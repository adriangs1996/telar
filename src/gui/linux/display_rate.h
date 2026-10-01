#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "outputs.h"

// Window-thread follower of the outputs the window's surface is on, and the
// refresh interval of the fastest of them. Holds no allocation.
typedef struct {
    telar_outputs *outputs;
    telar_output_set set;
    uint64_t reported_ns;
    bool changed;
} telar_display_rate;

// Follows enter and leave on the window's surface; call once, before its
// first commit. False when the table watches all the sets it can.
// Example: telar_display_rate_attach(&window.rate, &window.outputs, window.surface).
bool telar_display_rate_attach(telar_display_rate *self, telar_outputs *outputs, struct wl_surface *surface);
// True once per change of the refresh interval, with the new interval in
// nanoseconds. Example: if (telar_display_rate_take(&rate, &ns)) report(ns).
bool telar_display_rate_take(telar_display_rate *self, uint64_t *interval_ns);
void telar_display_rate_deinit(telar_display_rate *self);
