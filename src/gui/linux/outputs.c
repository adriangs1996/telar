// Every wl_output the compositor advertises, bound once for the whole window.
// The cursor follows the scale of the outputs its surface entered and the
// window follows the refresh of the outputs its surface entered; each keeps
// its own entered set over this one table.
#include "outputs.h"
#include <string.h>

static uint32_t bit(size_t slot) {
    return (uint32_t)1 << slot;
}

static void notify(telar_outputs *self, size_t slot) {
    for (size_t i = 0; i < self->set_count; i++) {
        telar_output_set *set = self->sets[i];
        if ((set->entered & bit(slot)) && set->changed != NULL) {
            set->changed(set->data);
        }
    }
}

static size_t slot_of(const telar_outputs *self, const telar_output *output) {
    return (size_t)(output - self->slots);
}

// Version 1 outputs send no `done`; their mode and scale apply at once.
static void settle(telar_output *output) {
    if (wl_output_get_version(output->handle) < WL_OUTPUT_DONE_SINCE_VERSION) {
        notify(output->owner, slot_of(output->owner, output));
    }
}

static void output_geometry(void *data, struct wl_output *output, int32_t x, int32_t y, int32_t width, int32_t height, int32_t subpixel, const char *make, const char *model, int32_t transform) {
    (void)data; (void)output; (void)x; (void)y; (void)width; (void)height;
    (void)subpixel; (void)make; (void)model; (void)transform;
}

static void output_mode(void *data, struct wl_output *output, uint32_t flags, int32_t width, int32_t height, int32_t refresh) {
    (void)output; (void)width; (void)height;
    telar_output *self = data;
    if (!(flags & WL_OUTPUT_MODE_CURRENT)) {
        return;
    }

    self->refresh_mhz = refresh > 0 ? (uint32_t)refresh : 0;
    settle(self);
}

static void output_done(void *data, struct wl_output *output) {
    (void)output;
    telar_output *self = data;
    notify(self->owner, slot_of(self->owner, self));
}

static void output_scale(void *data, struct wl_output *output, int32_t factor) {
    (void)output;
    telar_output *self = data;
    self->scale = factor;
    settle(self);
}

static const struct wl_output_listener output_listener = {
    .geometry = output_geometry, .mode = output_mode, .done = output_done, .scale = output_scale,
};

static void release(telar_output *output) {
    if (output->handle != NULL) {
        if (wl_output_get_version(output->handle) >= WL_OUTPUT_RELEASE_SINCE_VERSION) {
            wl_output_release(output->handle);
        } else {
            wl_output_destroy(output->handle);
        }
    }

    *output = (telar_output){0};
}

void telar_outputs_global(telar_outputs *self, const telar_registry_global *global) {
    if (strcmp(global->interface, wl_output_interface.name) != 0) {
        return;
    }

    // Outputs past the limit stay unbound: a surface on one of them keeps
    // what the outputs it is also on report.
    for (size_t i = 0; i < TELAR_OUTPUT_LIMIT; i++) {
        telar_output *output = &self->slots[i];
        if (output->handle != NULL) {
            continue;
        }

        *output = (telar_output){0};
        output->handle = wl_registry_bind(global->registry, global->name, &wl_output_interface, global->version < 3 ? global->version : 3);
        if (output->handle == NULL) {
            return;
        }

        output->owner = self;
        output->global = global->name;
        output->scale = 1;
        wl_output_add_listener(output->handle, &output_listener, output);
        return;
    }
}

void telar_outputs_remove(telar_outputs *self, uint32_t name) {
    for (size_t i = 0; i < TELAR_OUTPUT_LIMIT; i++) {
        if (self->slots[i].handle == NULL || self->slots[i].global != name) {
            continue;
        }

        release(&self->slots[i]);
        for (size_t j = 0; j < self->set_count; j++) {
            telar_output_set *set = self->sets[j];
            if (!(set->entered & bit(i))) {
                continue;
            }

            set->entered &= ~bit(i);
            if (set->changed != NULL) {
                set->changed(set->data);
            }
        }

        return;
    }
}

bool telar_outputs_watch(telar_outputs *self, telar_output_set *set) {
    if (self->set_count == TELAR_OUTPUT_SETS) {
        return false;
    }

    set->entered = 0;
    self->sets[self->set_count++] = set;
    return true;
}

void telar_outputs_unwatch(telar_outputs *self, telar_output_set *set) {
    for (size_t i = 0; i < self->set_count; i++) {
        if (self->sets[i] == set) {
            self->sets[i] = self->sets[--self->set_count];
            self->sets[self->set_count] = NULL;
            return;
        }
    }
}

static bool mark(telar_outputs *self, telar_output_set *set, struct wl_output *handle, bool entered) {
    // A surface may name an output the compositor already withdrew; its
    // proxy is NULL by then and matches no slot.
    if (handle == NULL) {
        return false;
    }

    for (size_t i = 0; i < TELAR_OUTPUT_LIMIT; i++) {
        if (self->slots[i].handle != handle) {
            continue;
        }

        uint32_t previous = set->entered;
        set->entered = entered ? previous | bit(i) : previous & ~bit(i);
        return set->entered != previous;
    }

    return false;
}

bool telar_outputs_enter(telar_outputs *self, telar_output_set *set, struct wl_output *handle) {
    return mark(self, set, handle, true);
}

bool telar_outputs_leave(telar_outputs *self, telar_output_set *set, struct wl_output *handle) {
    return mark(self, set, handle, false);
}

void telar_outputs_deinit(telar_outputs *self) {
    for (size_t i = 0; i < TELAR_OUTPUT_LIMIT; i++) {
        release(&self->slots[i]);
    }

    for (size_t i = 0; i < self->set_count; i++) {
        self->sets[i]->entered = 0;
    }
}
