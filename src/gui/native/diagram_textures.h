// Shared host validation runs before texture mutation or reading pixel bytes.
#ifndef TELAR_GUI_DIAGRAM_TEXTURES_H
#define TELAR_GUI_DIAGRAM_TEXTURES_H
#include "telar_gui.h"
#include <stdbool.h>

static inline bool telar_gui_diagrams_valid(const telar_gui_frame *frame, uint32_t device_max_side) {
    uint64_t total = 0;
    for (unsigned i = 0; i < TELAR_GUI_DIAGRAM_SLOTS; i++) {
        const telar_gui_diagram_texture *image = &frame->diagrams[i];
        if (!image->pixels) {
            if (image->width || image->height || image->version) {
                return false;
            }
            continue;
        }
        if (!image->width || !image->height || !image->version ||
            image->width > TELAR_GUI_DIAGRAM_MAX_SIDE || image->height > TELAR_GUI_DIAGRAM_MAX_SIDE ||
            image->width > device_max_side || image->height > device_max_side) {
            return false;
        }
        uint64_t pixels = (uint64_t)image->width * image->height;
        if (pixels > TELAR_GUI_DIAGRAM_MAX_PIXELS) {
            return false;
        }
        total += pixels;
    }
    return total <= TELAR_GUI_DIAGRAM_FRAME_PIXELS;
}
#endif
