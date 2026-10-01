// The refresh rate of the outputs the window's surface is on, read from each
// output's current mode in the shared output table. The window paces frames
// to the fastest of them: a window spanning a 60 Hz and a 144 Hz output
// presents at 144, and the compositor's frame callbacks hold it to what each
// output shows.
#include "display_rate.h"

static const uint64_t ns_per_millihertz_period = 1000000000000ull;

static void outputs_changed(void *data) {
    telar_display_rate *self = data;
    self->changed = true;
}

static void surface_enter(void *data, struct wl_surface *surface, struct wl_output *output) {
    (void)surface;
    telar_display_rate *self = data;
    if (telar_outputs_enter(self->outputs, &self->set, output)) {
        self->changed = true;
    }
}

static void surface_leave(void *data, struct wl_surface *surface, struct wl_output *output) {
    (void)surface;
    telar_display_rate *self = data;
    if (telar_outputs_leave(self->outputs, &self->set, output)) {
        self->changed = true;
    }
}

#ifdef WL_SURFACE_PREFERRED_BUFFER_SCALE_SINCE_VERSION
static void preferred_scale(void *data, struct wl_surface *surface, int32_t factor) {
    (void)data; (void)surface; (void)factor;
}

static void preferred_transform(void *data, struct wl_surface *surface, uint32_t transform) {
    (void)data; (void)surface; (void)transform;
}
#endif

static const struct wl_surface_listener surface_listener = {
    .enter = surface_enter, .leave = surface_leave,
#ifdef WL_SURFACE_PREFERRED_BUFFER_SCALE_SINCE_VERSION
    .preferred_buffer_scale = preferred_scale,
    .preferred_buffer_transform = preferred_transform,
#endif
};

bool telar_display_rate_attach(telar_display_rate *self, telar_outputs *outputs, struct wl_surface *surface) {
    if (surface == NULL) {
        return false;
    }

    self->outputs = outputs;
    self->set = (telar_output_set){.changed = outputs_changed, .data = self};
    if (!telar_outputs_watch(outputs, &self->set)) {
        self->outputs = NULL;
        return false;
    }

    wl_surface_add_listener(surface, &surface_listener, self);
    return true;
}

bool telar_display_rate_take(telar_display_rate *self, uint64_t *interval_ns) {
    if (!self->changed || self->outputs == NULL) {
        return false;
    }

    self->changed = false;
    uint32_t fastest = 0;
    for (size_t i = 0; i < TELAR_OUTPUT_LIMIT; i++) {
        const telar_output *output = &self->outputs->slots[i];
        if ((self->set.entered & ((uint32_t)1 << i)) && output->refresh_mhz > fastest) {
            fastest = output->refresh_mhz;
        }
    }

    if (fastest == 0) {
        return false;
    }

    uint64_t interval = ns_per_millihertz_period / fastest;
    if (interval == self->reported_ns) {
        return false;
    }

    self->reported_ns = interval;
    *interval_ns = interval;
    return true;
}

void telar_display_rate_deinit(telar_display_rate *self) {
    if (self->outputs != NULL) {
        telar_outputs_unwatch(self->outputs, &self->set);
        self->outputs = NULL;
    }
}
