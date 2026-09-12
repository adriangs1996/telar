#ifndef TELAR_INPUT_H
#define TELAR_INPUT_H
#include <wayland-client.h>
#include "../native/telar_gui.h"
typedef struct telar_input telar_input;
telar_input *telar_input_create(void *context, const telar_gui_callbacks *callbacks);
void telar_input_global(telar_input *, struct wl_registry *, uint32_t name, const char *interface, uint32_t version);
void telar_input_destroy(telar_input *);
int telar_input_fd(telar_input *);
int telar_input_timeout(telar_input *);
void telar_input_dispatch(telar_input *);
#endif
