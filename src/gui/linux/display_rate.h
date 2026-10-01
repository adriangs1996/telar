#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "registry.h"

#define TELAR_DISPLAY_OUTPUT_LIMIT 32

struct telar_display_rate;

typedef struct {
    struct wl_output *handle;
    struct telar_display_rate *owner;
    uint32_t global;
    // The current mode's refresh in millihertz; zero when the compositor
    // reports none, as a virtual output may.
    uint32_t refresh_mhz;
    bool entered;
} telar_display_output;

// Window-thread owner of the outputs the window's surface is on, and the
// refresh interval of the fastest of them. Holds no allocation.
typedef struct telar_display_rate {
    telar_display_output outputs[TELAR_DISPLAY_OUTPUT_LIMIT];
    uint64_t reported_ns;
    bool changed;
} telar_display_rate;

void telar_display_rate_global(telar_display_rate *self, const telar_registry_global *global);
void telar_display_rate_remove(telar_display_rate *self, uint32_t name);
// Follows enter and leave on the window's surface; call once, before its
// first commit. Example: telar_display_rate_attach(&window.rate, window.surface).
void telar_display_rate_attach(telar_display_rate *self, struct wl_surface *surface);
// True once per change of the refresh interval, with the new interval in
// nanoseconds. Example: if (telar_display_rate_take(&rate, &ns)) report(ns).
bool telar_display_rate_take(telar_display_rate *self, uint64_t *interval_ns);
void telar_display_rate_deinit(telar_display_rate *self);
