// The whole contract between Zig and a native backend: a frame is a quad
// buffer plus one alpha page, and the backend calls back for each paint.
// These mirror `render/Quad.zig`, `native/Frame.zig` and `native/Viewport.zig`
// field for field.
#ifndef TELAR_GUI_H
#define TELAR_GUI_H

#include <stddef.h>
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
  uint64_t token;
  const telar_gui_quad *quads;
  uint32_t quad_count;
  const uint8_t *atlas;
  uint32_t atlas_side;
  uint32_t atlas_version;
  float background[4];
} telar_gui_frame;

// Input kinds: 1 committed UTF-8 text, 2 clipboard paste, 3 semantic key.
// Key codes: 0 Unicode scalar, then enter, tab, backspace, escape, up,
// down, left, right, home, end, delete, page-up, page-down.
// Modifiers: shift=1, alt=2, ctrl=4. Phases: press=1, repeat=2, release=3.
typedef struct {
  uint32_t kind, code, mods, phase;
  const uint8_t *text;
  size_t len;
} telar_gui_input;

typedef struct {
  void (*render)(void *, telar_gui_viewport, telar_gui_frame *);
  int (*pump)(void *);
  void (*complete)(void *, uint64_t, int);
  int (*input)(void *, telar_gui_input);
  int wake_fd;
} telar_gui_callbacks;

int telar_gui_run(const char *title, void *context,
                  const telar_gui_callbacks *callbacks);
int telar_gui_pipe(int *fds);
void telar_gui_wake(int fd);
void telar_gui_drain(int fd);
void telar_gui_close_pipe(int *fds);
int telar_gui_clipboard(const uint8_t *bytes, size_t len);
void telar_gui_local_time(uint16_t *output);
#endif
