// A Vulkan consumer of the quad buffer, drawing on one Wayland surface.
#ifndef TELAR_GUI_RENDERER_H
#define TELAR_GUI_RENDERER_H

#include <stdbool.h>
#include <wayland-client.h>

#include "../native/telar_gui.h"

typedef struct telar_renderer telar_renderer;

// Creates the instance, device, swapchain and pipeline for `surface`.
// Returns NULL after printing the failing step to stderr.
telar_renderer *telar_renderer_create(struct wl_display *display, struct wl_surface *surface,
                                      telar_gui_viewport viewport);

// Runs on the single consumer worker. Returns after GPU consumption; never
// calls the client or Wayland event handlers. A stale swapchain is rebuilt.
enum telar_render_result { TELAR_RENDER_FAILED, TELAR_RENDER_DELIVERED, TELAR_RENDER_RETRY };
enum telar_render_result telar_renderer_draw(telar_renderer *renderer, telar_gui_viewport viewport,
                                             const telar_gui_frame *frame);

// Window thread, no frame in flight: takes the frame's image releases and
// uploads whether or not the frame is submitted.
void telar_renderer_accept_images(telar_renderer *renderer, const telar_gui_frame *frame);
// Readable when image uploads finished; take reports each exactly once.
int telar_renderer_images_fd(telar_renderer *renderer);
void telar_renderer_take_images(telar_renderer *renderer, void (*ready)(void *, uint32_t, int), void *context);

void telar_renderer_destroy(telar_renderer *renderer);

#endif
