// The refresh rate of the outputs a Wayland surface is on, read from each
// output's current mode. The window paces frames to the fastest of them: a
// window spanning a 60 Hz and a 144 Hz output presents at 144, and the
// compositor's frame callbacks hold it to what each output shows.
#include "display_rate.h"
#include <string.h>

static const uint64_t ns_per_millihertz_period = 1000000000000ull;

static void output_geometry(void *data, struct wl_output *output, int32_t x, int32_t y, int32_t width, int32_t height, int32_t subpixel, const char *make, const char *model, int32_t transform) {
    (void)data; (void)output; (void)x; (void)y; (void)width; (void)height;
    (void)subpixel; (void)make; (void)model; (void)transform;
}

static void output_mode(void *data, struct wl_output *output, uint32_t flags, int32_t width, int32_t height, int32_t refresh) {
    (void)output; (void)width; (void)height;
    telar_display_output *self = data;
    if (!(flags & WL_OUTPUT_MODE_CURRENT)) {
        return;
    }

    self->refresh_mhz = refresh > 0 ? (uint32_t)refresh : 0;
    self->owner->changed = true;
}

static void output_done(void *data, struct wl_output *output) {
    (void)data; (void)output;
}

static void output_scale(void *data, struct wl_output *output, int32_t factor) {
    (void)data; (void)output; (void)factor;
}

static const struct wl_output_listener output_listener = {
    .geometry = output_geometry, .mode = output_mode, .done = output_done, .scale = output_scale,
};

static void surface_output(telar_display_rate *self, struct wl_output *handle, bool entered) {
    for (size_t i = 0; i < TELAR_DISPLAY_OUTPUT_LIMIT; i++) {
        if (self->outputs[i].handle == handle) {
            self->outputs[i].entered = entered;
            self->changed = true;
            return;
        }
    }
}

static void surface_enter(void *data, struct wl_surface *surface, struct wl_output *output) {
    (void)surface;
    surface_output(data, output, true);
}

static void surface_leave(void *data, struct wl_surface *surface, struct wl_output *output) {
    (void)surface;
    surface_output(data, output, false);
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

static void destroy_output(telar_display_output *output) {
    if (output->handle != NULL) {
        if (wl_output_get_version(output->handle) >= WL_OUTPUT_RELEASE_SINCE_VERSION) {
            wl_output_release(output->handle);
        } else {
            wl_output_destroy(output->handle);
        }
    }

    *output = (telar_display_output){0};
}

void telar_display_rate_global(telar_display_rate *self, const telar_registry_global *global) {
    if (strcmp(global->interface, wl_output_interface.name) != 0) {
        return;
    }

    // Outputs past the limit stay unbound: a surface on one of them keeps
    // the interval of the outputs it is also on, or the last reported.
    for (size_t i = 0; i < TELAR_DISPLAY_OUTPUT_LIMIT; i++) {
        telar_display_output *output = &self->outputs[i];
        if (output->handle != NULL) {
            continue;
        }

        output->handle = wl_registry_bind(global->registry, global->name, &wl_output_interface, global->version < 3 ? global->version : 3);
        if (output->handle == NULL) {
            return;
        }

        output->global = global->name;
        output->owner = self;
        wl_output_add_listener(output->handle, &output_listener, output);
        return;
    }
}

void telar_display_rate_remove(telar_display_rate *self, uint32_t name) {
    for (size_t i = 0; i < TELAR_DISPLAY_OUTPUT_LIMIT; i++) {
        if (self->outputs[i].handle != NULL && self->outputs[i].global == name) {
            destroy_output(&self->outputs[i]);
            self->changed = true;
            return;
        }
    }
}

void telar_display_rate_attach(telar_display_rate *self, struct wl_surface *surface) {
    if (surface == NULL) {
        return;
    }

    wl_surface_add_listener(surface, &surface_listener, self);
}

bool telar_display_rate_take(telar_display_rate *self, uint64_t *interval_ns) {
    if (!self->changed) {
        return false;
    }

    self->changed = false;
    uint32_t fastest = 0;
    for (size_t i = 0; i < TELAR_DISPLAY_OUTPUT_LIMIT; i++) {
        const telar_display_output *output = &self->outputs[i];
        if (output->handle != NULL && output->entered && output->refresh_mhz > fastest) {
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
    for (size_t i = 0; i < TELAR_DISPLAY_OUTPUT_LIMIT; i++) {
        destroy_output(&self->outputs[i]);
    }
}
