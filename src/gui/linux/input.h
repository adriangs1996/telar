#ifndef TELAR_INPUT_H
#define TELAR_INPUT_H
#include <wayland-client.h>
#include "../native/telar_gui.h"
#include "registry.h"
typedef struct telar_input telar_input;
telar_input *telar_input_create(void *context, const telar_gui_callbacks *callbacks);
int telar_input_clipboard(telar_input *, const uint8_t *bytes, size_t len);
void telar_input_fullscreen(telar_input *, void *context, void (*toggle)(void *));
void telar_input_global(telar_input *, const telar_registry_global *);
void telar_input_remove(telar_input *, uint32_t name);
void telar_input_pointer_update(telar_input *);
void telar_input_services(telar_input *);
void telar_input_destroy(telar_input *);
int telar_input_fd(telar_input *);
int telar_input_timeout(telar_input *);
void telar_input_dispatch(telar_input *);
#endif
