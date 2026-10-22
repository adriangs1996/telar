#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct telar_server;

enum telar_layer {
  TELAR_BACKGROUND,
  TELAR_WINDOWS,
  TELAR_OVERLAY
};

struct telar_box {
  int x, y, width, height;
};

struct telar_output_info {
  uint32_t id;
  const char *name;
  struct telar_box box;
  struct telar_box usable;
  float scale;
  uint64_t space;
};

struct telar_surface_info {
  uint32_t resource;
  struct telar_box box;
};

struct telar_window_info {
  uint32_t id;
  int64_t pid;
  const char *application;
  const char *title;
  struct telar_box box;
  uint64_t space;
  bool floating;
};

struct telar_key_event {
  uint32_t code;
  uint32_t symbol;
  uint32_t unicode;
  uint32_t modifiers;
  bool pressed;
};

enum telar_modifier {
  TELAR_SHIFT = 1,
  TELAR_ALT = 2,
  TELAR_CONTROL = 4,
  TELAR_SUPER = 8,
};

struct telar_hooks {
  void *context;
  void (*dispatch)(void *context);
  void (*changed)(void *context);
  bool (*key)(void *context, const struct telar_key_event *event);
  void (*cancel_shortcuts)(void *context);
  void (*lock)(void *context);
};

// A nonzero resource addresses a surface owned by this process; otherwise id is a
// compositor-assigned foreign window ID. Neither accepts another client's resource ID.
struct telar_target {
  uint32_t id;
  uint32_t resource;
};

struct telar_placement {
  struct telar_target target;
  struct telar_box box;
  uint64_t space;
  enum telar_layer layer;
  bool visible;
  bool focusable;
};

// All functions run on the compositor thread, including destruction. The command
// eventfd is owned by the caller and wakes dispatch without touching Wayland objects.
struct telar_server *telar_server_create(const struct telar_hooks *hooks, int command_fd);
const char *telar_server_socket(struct telar_server *server);
const char *telar_server_xdisplay(struct telar_server *server);
void telar_server_run(struct telar_server *server);
void telar_server_stop(struct telar_server *server);
void telar_server_destroy(struct telar_server *server);
void telar_server_outputs(struct telar_server *server,
                          void *context,
                          void (*visit)(void *, const struct telar_output_info *));
void telar_server_windows(struct telar_server *server,
                          void *context,
                          void (*visit)(void *, const struct telar_window_info *));
void telar_server_surfaces(struct telar_server *server,
                           void *context,
                           void (*visit)(void *, const struct telar_surface_info *));
uint32_t telar_server_focused(struct telar_server *server);
uint64_t telar_server_focused_space(struct telar_server *server);
void telar_server_place(struct telar_server *server, const struct telar_placement *placement);
void telar_server_visible(struct telar_server *server, struct telar_target target, bool visible);
void telar_server_focus(struct telar_server *server, struct telar_target target);
void telar_server_raise(struct telar_server *server, struct telar_target target);
void telar_server_close(struct telar_server *server, struct telar_target target);
void telar_server_space(struct telar_server *server, uint32_t output, uint64_t space);
void telar_server_workarea(struct telar_server *server, uint32_t output, struct telar_box box);
void telar_server_move_space(struct telar_server *server, uint64_t from, uint64_t to);

#ifdef __cplusplus
}
#endif
