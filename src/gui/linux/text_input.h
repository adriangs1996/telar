#ifndef TELAR_TEXT_INPUT_H
#define TELAR_TEXT_INPUT_H
#include <stdbool.h>
#include <wayland-client.h>
#include "../native/telar_gui.h"
#include "registry.h"

typedef struct telar_text_input telar_text_input;
telar_text_input *telar_text_input_create(void *, const telar_gui_callbacks *);
void telar_text_input_global(telar_text_input *, const telar_registry_global *);
void telar_text_input_remove(telar_text_input *, uint32_t name);
void telar_text_input_seat(telar_text_input *, struct wl_seat *);
void telar_text_input_update(telar_text_input *);
void telar_text_input_destroy(telar_text_input *);
#endif
