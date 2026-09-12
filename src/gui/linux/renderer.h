// A Vulkan consumer of the quad buffer, drawing on one Wayland surface.
#ifndef TELAR_GUI_RENDERER_H
#define TELAR_GUI_RENDERER_H

#include <stdbool.h>
#include <wayland-client.h>

#include "../native/telar_gui.h"

typedef struct telar_renderer telar_renderer;

// Creates the instance, device, swapchain and pipeline for `surface`.
// Returns NULL after printing the failing step to stderr.
telar_renderer *telar_renderer_create(struct wl_display *display, struct wl_surface *surface, telar_gui_viewport viewport);

// Draws one frame. A stale swapchain is rebuilt for `viewport` before drawing.
bool telar_renderer_draw(telar_renderer *renderer, telar_gui_viewport viewport, const telar_gui_frame *frame);

void telar_renderer_destroy(telar_renderer *renderer);

#endif
