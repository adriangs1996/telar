#include "cursor_theme.h"
#include "cursor_shapes.h"
#include <stdlib.h>
#include <limits.h>
#include <string.h>
#include <wayland-cursor.h>

#define OUTPUT_LIMIT 32
#define SCALE_LIMIT 8

struct cursor_output {
    struct wl_output *handle;
    struct telar_cursor_theme *owner;
    uint32_t global;
    int32_t scale;
    bool entered;
};

struct cursor_image {
    struct wl_buffer *buffer;
    uint32_t width, height, hotspot_x, hotspot_y;
};

struct telar_cursor_theme {
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct wl_surface *surface;
    struct wl_cursor_theme *theme;
    struct cursor_output outputs[OUTPUT_LIMIT];
    struct cursor_image images[TELAR_CURSOR_SHAPES];
    uint32_t compositor_global, shm_global, shape;
    int32_t size, scale, loaded_scale, attempted_scale, preferred_scale;
    bool applied;
};

static int32_t bounded_scale(int32_t scale) {
    return scale < 1 ? 1 : scale > SCALE_LIMIT ? SCALE_LIMIT : scale;
}

static void update_scale(telar_cursor_theme *self) {
    int32_t scale = self->preferred_scale;
    if (scale == 0) {
        scale = 1;
        for (size_t i = 0; i < OUTPUT_LIMIT; i++) {
            const struct cursor_output *output = &self->outputs[i];
            if (output->entered && output->scale > scale) {
                scale = output->scale;
            }
        }
    }

    scale = bounded_scale(scale);
    if (self->scale != scale) {
        self->scale = scale;
        self->applied = false;
    }
}

static void output_geometry(void *data, struct wl_output *output, int32_t x, int32_t y, int32_t width, int32_t height, int32_t subpixel, const char *make, const char *model, int32_t transform) {
    (void)data; (void)output; (void)x; (void)y; (void)width; (void)height;
    (void)subpixel; (void)make; (void)model; (void)transform;
}

static void output_mode(void *data, struct wl_output *output, uint32_t flags, int32_t width, int32_t height, int32_t refresh) {
    (void)data; (void)output; (void)flags; (void)width; (void)height; (void)refresh;
}

static void output_done(void *data, struct wl_output *output) {
    (void)output;
    struct cursor_output *self = data;
    update_scale(self->owner);
}

static void output_scale(void *data, struct wl_output *output, int32_t factor) {
    (void)output;
    struct cursor_output *self = data;
    self->scale = bounded_scale(factor);
}

static const struct wl_output_listener output_listener = {
    .geometry = output_geometry, .mode = output_mode, .done = output_done, .scale = output_scale,
};

static void surface_output(telar_cursor_theme *self, struct wl_output *handle, bool entered) {
    for (size_t i = 0; i < OUTPUT_LIMIT; i++) {
        if (self->outputs[i].handle == handle) {
            self->outputs[i].entered = entered;
            update_scale(self);
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
    (void)surface;
    telar_cursor_theme *self = data;
    self->preferred_scale = bounded_scale(factor);
    update_scale(self);
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

static void destroy_output(struct cursor_output *output) {
    if (output->handle != NULL) {
        if (wl_output_get_version(output->handle) >= WL_OUTPUT_RELEASE_SINCE_VERSION) {
            wl_output_release(output->handle);
        } else {
            wl_output_destroy(output->handle);
        }
    }

    *output = (struct cursor_output){0};
}

telar_cursor_theme *telar_cursor_theme_create(void) {
    telar_cursor_theme *self = calloc(1, sizeof *self);
    if (self == NULL) {
        return NULL;
    }

    self->scale = 1;
    self->size = 24;
    const char *configured = getenv("XCURSOR_SIZE");
    if (configured != NULL) {
        char *end;
        long size = strtol(configured, &end, 10);
        if (end != configured && *end == 0 && size >= 1 && size <= 128) {
            self->size = (int32_t)size;
        }
    }

    return self;
}

void telar_cursor_theme_global(telar_cursor_theme *self, const telar_registry_global *global) {
    if (!strcmp(global->interface, wl_compositor_interface.name) && self->compositor == NULL) {
        uint32_t version = 4;
#ifdef WL_SURFACE_PREFERRED_BUFFER_SCALE_SINCE_VERSION
        version = 6;
#endif
        self->compositor = wl_registry_bind(global->registry, global->name, &wl_compositor_interface, global->version < version ? global->version : version);
        self->compositor_global = global->name;
        self->attempted_scale = 0;
    } else if (!strcmp(global->interface, wl_shm_interface.name) && self->shm == NULL) {
        self->shm = wl_registry_bind(global->registry, global->name, &wl_shm_interface, 1);
        self->shm_global = global->name;
        self->attempted_scale = 0;
    } else if (!strcmp(global->interface, wl_output_interface.name)) {
        for (size_t i = 0; i < OUTPUT_LIMIT; i++) {
            struct cursor_output *output = &self->outputs[i];
            if (output->handle == NULL) {
                output->handle = wl_registry_bind(global->registry, global->name, &wl_output_interface, global->version < 3 ? global->version : 3);
                if (output->handle == NULL) {
                    return;
                }

                output->global = global->name;
                output->scale = 1;
                output->owner = self;
                wl_output_add_listener(output->handle, &output_listener, output);
                break;
            }
        }
    }
}

static void discard_surface(telar_cursor_theme *self) {
    if (self->surface != NULL) {
        wl_surface_destroy(self->surface);
        self->surface = NULL;
    }

    self->preferred_scale = 0;
    for (size_t i = 0; i < OUTPUT_LIMIT; i++) {
        self->outputs[i].entered = false;
    }

    self->attempted_scale = 0;
    self->applied = false;
    update_scale(self);
}

void telar_cursor_theme_remove(telar_cursor_theme *self, uint32_t name) {
    if (self->compositor != NULL && self->compositor_global == name) {
        discard_surface(self);
        wl_compositor_destroy(self->compositor);
        self->compositor = NULL;
    }

    if (self->shm != NULL && self->shm_global == name) {
        discard_surface(self);
        if (self->theme != NULL) {
            wl_cursor_theme_destroy(self->theme);
            self->theme = NULL;
        }

        memset(self->images, 0, sizeof self->images);
        self->loaded_scale = 0;
        wl_shm_destroy(self->shm);
        self->shm = NULL;
    }

    for (size_t i = 0; i < OUTPUT_LIMIT; i++) {
        if (self->outputs[i].handle != NULL && self->outputs[i].global == name) {
            destroy_output(&self->outputs[i]);
            update_scale(self);
            break;
        }
    }
}

static struct cursor_image load_image(struct wl_cursor_theme *theme, uint32_t shape) {
    struct wl_cursor *cursor = wl_cursor_theme_get_cursor(theme, telar_cursor_shapes[shape].name);
    if (cursor == NULL) {
        cursor = wl_cursor_theme_get_cursor(theme, telar_cursor_shapes[shape].alias);
    }

    if (cursor == NULL || cursor->image_count == 0) {
        return (struct cursor_image){0};
    }

    // Compositors animate protocol cursors. The fallback retains the first image,
    // so a wait cursor never creates a timer or a terminal presentation request.
    struct wl_cursor_image *image = cursor->images[0];
    if (image->width == 0 || image->height == 0 || image->width > INT32_MAX - SCALE_LIMIT ||
        image->height > INT32_MAX - SCALE_LIMIT || image->hotspot_x >= image->width || image->hotspot_y >= image->height) {
        return (struct cursor_image){0};
    }

    return (struct cursor_image){.buffer = wl_cursor_image_get_buffer(image), .width = image->width,
        .height = image->height, .hotspot_x = image->hotspot_x, .hotspot_y = image->hotspot_y};
}

static void prepare(telar_cursor_theme *self) {
    if (self->attempted_scale == self->scale || self->compositor == NULL || self->shm == NULL) {
        return;
    }

    self->attempted_scale = self->scale;
    if (self->surface == NULL) {
        self->surface = wl_compositor_create_surface(self->compositor);
        if (self->surface == NULL) {
            return;
        }

        wl_surface_add_listener(self->surface, &surface_listener, self);
    }

    int32_t scale = wl_surface_get_version(self->surface) >= WL_SURFACE_SET_BUFFER_SCALE_SINCE_VERSION ? self->scale : 1;
    struct wl_cursor_theme *replacement = wl_cursor_theme_load(getenv("XCURSOR_THEME"), self->size * scale, self->shm);
    if (replacement == NULL) {
        return;
    }

    struct wl_cursor_theme *previous = self->theme;
    self->theme = replacement;
    self->loaded_scale = scale;
    for (uint32_t shape = 0; shape < TELAR_CURSOR_SHAPES; shape++) {
        self->images[shape] = load_image(replacement, shape);
        if (self->images[shape].buffer == NULL) {
            self->images[shape] = self->images[0];
        }
    }

    if (previous != NULL) {
        wl_cursor_theme_destroy(previous);
    }

    self->applied = false;
}

void telar_cursor_theme_apply(telar_cursor_theme *self, const telar_cursor_request *request) {
    prepare(self);
    uint32_t shape = request->shape < TELAR_CURSOR_SHAPES ? request->shape : 0;
    if (self->surface == NULL || self->theme == NULL || (self->applied && self->shape == shape)) {
        return;
    }

    const struct cursor_image *image = &self->images[shape];
    if (image->buffer == NULL) {
        return;
    }

    int32_t scale = self->loaded_scale;
    if (wl_surface_get_version(self->surface) >= WL_SURFACE_SET_BUFFER_SCALE_SINCE_VERSION) {
        wl_surface_set_buffer_scale(self->surface, scale);
    }

    wl_pointer_set_cursor(request->pointer, request->serial, self->surface, (int32_t)image->hotspot_x / scale, (int32_t)image->hotspot_y / scale);
    wl_surface_attach(self->surface, image->buffer, 0, 0);
    wl_surface_damage(self->surface, 0, 0, (int32_t)(image->width + scale - 1) / scale, (int32_t)(image->height + scale - 1) / scale);
    wl_surface_commit(self->surface);
    self->shape = shape;
    self->applied = true;
}

void telar_cursor_theme_invalidate(telar_cursor_theme *self) {
    self->applied = false;
}

void telar_cursor_theme_destroy(telar_cursor_theme *self) {
    if (self == NULL) {
        return;
    }

    discard_surface(self);
    if (self->theme != NULL) {
        wl_cursor_theme_destroy(self->theme);
    }

    for (size_t i = 0; i < OUTPUT_LIMIT; i++) {
        destroy_output(&self->outputs[i]);
    }

    if (self->shm != NULL) {
        wl_shm_destroy(self->shm);
    }

    if (self->compositor != NULL) {
        wl_compositor_destroy(self->compositor);
    }

    free(self);
}
