#define _POSIX_C_SOURCE 200809L
#include "frame_clock.h"
#include <time.h>

static const int64_t frame_ns = 16666667;

static int64_t now_ns(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000000000 + now.tv_nsec;
}

static void refreshed(void *data, struct wl_callback *callback, uint32_t time) {
    (void)time;
    telar_frame_clock *self = data;
    wl_callback_destroy(callback);
    self->callback = NULL;
}

static const struct wl_callback_listener listener = {.done = refreshed};

int telar_frame_clock_timeout(const telar_frame_clock *self) {
    if (self->callback != NULL) {
        return -1;
    }
    int64_t delay = self->next_draw_ns - now_ns();
    return delay <= 0 ? 0 : (int)((delay + 999999) / 1000000);
}

bool telar_frame_clock_ready(const telar_frame_clock *self) { return telar_frame_clock_timeout(self) == 0; }

bool telar_frame_clock_request(telar_frame_clock *self, struct wl_surface *surface) {
    if (!telar_frame_clock_ready(self)) {
        return false;
    }
    self->callback = wl_surface_frame(surface);
    if (self->callback == NULL) {
        return false;
    }
    wl_callback_add_listener(self->callback, &listener, self);
    int64_t now = now_ns();
    self->next_draw_ns = now - self->next_draw_ns >= frame_ns ? now + frame_ns : self->next_draw_ns + frame_ns;
    return true;
}

void telar_frame_clock_cancel(telar_frame_clock *self) {
    if (self->callback != NULL) {
        wl_callback_destroy(self->callback);
    }
    self->callback = NULL;
}
