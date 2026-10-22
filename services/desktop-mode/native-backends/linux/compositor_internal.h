#pragma once

#include "compositor.h"
#include <errno.h>
#include <string.h>
#include <wlr/types/wlr_viewporter.h>
#include <wlr/types/wlr_fractional_scale_v1.h>
#include <wlr/types/wlr_xdg_output_v1.h>
#include <wlr/types/wlr_xdg_decoration_v1.h>
#include <wlr/types/wlr_primary_selection.h>
#include <wlr/types/wlr_primary_selection_v1.h>
#include <wlr/types/wlr_screencopy_v1.h>
#include <wlr/types/wlr_data_control_v1.h>
#include <wlr/types/wlr_cursor_shape_v1.h>
#include <wlr/xwayland/xwayland.h>
#include <assert.h>
#include <getopt.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/backend/session.h>
#include <wlr/render/allocator.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_input_device.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_pointer.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/util/log.h>
#include <xkbcommon/xkbcommon.h>

enum telar_cursor_mode {
  TELAR_CURSOR_PASSTHROUGH,
  TELAR_CURSOR_MOVE,
  TELAR_CURSOR_RESIZE,
};

enum {
  max_windows = 2048,
  initial_window_width = 640,
  initial_window_height = 480
};

struct native_placement {
  struct wl_list link;
  struct telar_placement value;
};

struct telar_server {
  struct telar_hooks hooks;
  struct wl_event_source *commands;
  struct wl_event_source *changed_idle;
  const char *socket_name;
  struct wl_list natives;
  uint32_t next_window;
  uint32_t next_output;
  uint32_t focused;
  struct telar_target focus_request;
  uint64_t focused_space;
  bool destroying;
  struct wlr_scene_tree *layers[3];
  struct wlr_scene_tree *desktop_tree;
  struct wlr_scene_tree *fullscreen_tree;
  struct wlr_scene_tree *popup_tree;
  struct wlr_scene_tree *drag_tree;
  struct telar_lock *lock;
  struct telar_input_method *input_method;
  struct telar_shell *shell;
  struct telar_pointer *pointer;
  struct wlr_idle_notifier_v1 *idle;
  bool locked;
  struct wlr_compositor *compositor;
  struct wl_listener primary_selection;
  struct wl_listener cursor_shape;
  struct wlr_xwayland *xwayland;
  struct wl_listener new_xwayland;
  struct wl_listener xwayland_ready;
  struct wl_list xwindows;
  struct wl_display *wl_display;
  struct wlr_backend *backend;
  struct wlr_session *session;
  struct wlr_renderer *renderer;
  struct wlr_allocator *allocator;
  struct wlr_scene *scene;
  struct wlr_scene_output_layout *scene_layout;

  struct wlr_xdg_shell *xdg_shell;
  struct wl_listener new_xdg_toplevel;
  struct wl_listener new_xdg_popup;
  struct wl_list toplevels;

  struct wlr_cursor *cursor;
  struct wlr_xcursor_manager *cursor_mgr;
  struct wl_listener cursor_motion;
  struct wl_listener cursor_motion_absolute;
  struct wl_listener cursor_button;
  struct wl_listener cursor_axis;
  struct wl_listener cursor_frame;

  struct wlr_seat *seat;
  struct wl_listener new_input;
  struct wl_listener request_cursor;
  struct wl_listener pointer_focus_change;
  struct wl_listener request_set_selection;
  struct wl_list keyboards;
  enum telar_cursor_mode cursor_mode;
  struct telar_toplevel *grabbed_toplevel;
  double grab_x, grab_y;
  struct wlr_box grab_geobox;
  uint32_t resize_edges;

  struct wlr_output_layout *output_layout;
  struct wl_list outputs;
  struct wl_listener new_output;
};

struct telar_output {
  uint32_t id;
  uint64_t space;
  struct wl_list link;
  struct telar_server *server;
  struct wlr_output *wlr_output;
  struct wl_listener frame;
  struct wl_listener request_state;
  struct wl_listener destroy;
  struct wl_listener commit;
  struct wlr_box usable;
  struct wlr_box workarea;
};

struct telar_toplevel {
  uint32_t id;
  uint32_t resource;
  pid_t pid;
  uint64_t space;
  bool own;
  bool mapped;
  bool visible;
  bool focusable;
  bool fullscreen;
  bool maximized;
  struct wlr_box placement;
  enum telar_layer layer;
  struct wl_listener title;
  struct wl_listener app_id;
  int last_width, last_height;
  struct wl_list link;
  struct telar_server *server;
  struct wlr_xdg_toplevel *xdg_toplevel;
  struct wlr_scene_tree *scene_tree;
  struct wl_listener map;
  struct wl_listener unmap;
  struct wl_listener commit;
  struct wl_listener destroy;
  struct wl_listener request_move;
  struct wl_listener request_resize;
  struct wl_listener request_maximize;
  struct wl_listener request_fullscreen;
};

struct telar_popup {
  struct telar_server *server;
  struct wlr_scene_tree *parent;
  struct wlr_xdg_popup *xdg_popup;
  struct wl_listener commit;
  struct wl_listener destroy;
};

struct telar_keyboard {
  struct wl_list link;
  struct telar_server *server;
  struct wlr_keyboard *wlr_keyboard;

  struct wl_listener modifiers;
  struct wl_listener key;
  struct wl_listener destroy;
};

void telar_notify(struct telar_server *server);
void telar_focus_surface(struct telar_server *server, struct wlr_surface *surface);
bool telar_focus_allowed(struct telar_server *server, struct wlr_surface *surface);
struct telar_output *telar_output_for_space(struct telar_server *server, uint64_t space);
struct wlr_scene_tree *telar_surface_tree(struct telar_server *server, struct wlr_surface *surface);
void telar_restore_focus(struct telar_server *server);
void telar_arrange_windows(struct telar_server *server);
void telar_update_visibility(struct telar_server *server);
void telar_activate_surface(struct telar_server *server, struct wlr_surface *surface);
void telar_new_keyboard(struct telar_server *server, struct wlr_input_device *device);

bool telar_lock_init(struct telar_server *server);
void telar_lock_finish(struct telar_server *server);
void telar_lock_outputs(struct telar_server *server);

bool telar_input_method_init(struct telar_server *server);
void telar_input_method_finish(struct telar_server *server);
bool telar_input_method_key(struct telar_server *server,
                            struct wlr_keyboard *keyboard,
                            struct wlr_keyboard_key_event *event);
bool telar_input_method_modifiers(struct telar_server *server, struct wlr_keyboard *keyboard);
void telar_input_method_update(struct telar_server *server);

bool telar_shell_init(struct telar_server *server);
void telar_shell_finish(struct telar_server *server);
void telar_shell_outputs(struct telar_server *server);
void telar_shell_activity(struct telar_server *server);
void telar_shell_pointer(struct telar_server *server);
bool telar_shell_focus(struct telar_server *server, struct wlr_surface *surface);
bool telar_shell_exclusive(struct telar_server *server, struct wlr_surface *surface);
void telar_shell_visibility(struct telar_server *server);

void telar_create_popup(struct telar_server *server,
                        struct wlr_xdg_popup *popup,
                        struct wlr_scene_tree *parent);

bool telar_pointer_init(struct telar_server *server);
void telar_pointer_finish(struct telar_server *server);
bool telar_pointer_relative(struct telar_server *server, struct wlr_pointer_motion_event *event);
bool telar_pointer_absolute(struct telar_server *server,
                            struct wlr_pointer_motion_absolute_event *event);
void telar_pointer_configure(struct wlr_input_device *device);
