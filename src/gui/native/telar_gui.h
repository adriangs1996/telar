// The whole contract between Zig and a native backend: a frame is a quad
// buffer plus one alpha page, and the backend calls back for each paint.
// These mirror `render/Quad.zig`, `native/Frame.zig` and `native/Viewport.zig`
// field for field.
#ifndef TELAR_GUI_H
#define TELAR_GUI_H

#include <stdint.h>

typedef struct {
    float x, y, width, height;
    float u0, v0, u1, v1;
    float r, g, b, a;
} telar_gui_quad;

typedef struct {
    uint32_t width;
    uint32_t height;
    float scale;
} telar_gui_viewport;

typedef struct {
    const telar_gui_quad *quads;
    uint32_t quad_count;
    const uint8_t *atlas;
    uint32_t atlas_side;
    uint32_t atlas_version;
    float background[4];
} telar_gui_frame;

typedef void (*telar_gui_render_fn)(void *context, telar_gui_viewport viewport, telar_gui_frame *frame);

// Opens the window, runs the platform event loop on the calling thread and
// returns 0 when the window closes, or -1 when the backend cannot start.
int telar_gui_run(const char *title, void *context, telar_gui_render_fn render);

#endif
