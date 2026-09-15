// The whole contract between Zig and a native backend: a frame is a quad
// buffer, one alpha page and one RGBA sprite page, and the backend calls
// back for each paint.
// These mirror `render/Quad.zig`, `native/Frame.zig` and `native/Viewport.zig`
// field for field.
#ifndef TELAR_GUI_H
#define TELAR_GUI_H

#include <stddef.h>
#include <stdint.h>

#define TELAR_GUI_RANGE_NONE UINT32_MAX
#define TELAR_GUI_TEXT_CAPACITY 4096
#define TELAR_GUI_ACCESSIBILITY_CAPACITY 256

// Selection start/end mean anchor/head in UTF-8 bytes and may be reversed.
// Replacement start/end are ordered byte ranges; RANGE_NONE means no override.

// Every range is a UTF-8 byte offset. Geometry is content-relative device pixels.
typedef struct {
  uint64_t target_id, generation, revision;
  uint32_t enabled;
  uint32_t composition_active;
  const uint8_t *text;
  size_t len;
  uint32_t selection_start, selection_end;
  double x, y, width, height;
} telar_gui_text_context;

// kind: 1 read UTF-8 clipboard, 2 write UTF-8 clipboard. The backend copies
// borrowed bytes before requesting the next item. Every request completes.
typedef struct {
  uint32_t kind;
  uint64_t request_id, target_id, generation;
  const uint8_t *text;
  size_t len;
} telar_gui_host_request;

// Roles: group1, button2, text_field3, label4, tab5, list6, list_item7, terminal8.
// Flags: enabled1, focused2, selected4, editable8, multiline16, modal32.
// Actions: press1, focus2, set_value4, set_selection8, increment16, decrement32,
// copy64, cut128, paste256, replace_range512. Clipboard actions carry a UTF-8
// selection. Partial edits carry replacement offsets and expected text revision.
typedef struct {
  uint64_t id, generation, parent_id;
  uint32_t role, flags, actions;
  double x, y, width, height;
  const uint8_t *label;
  size_t label_len;
  const uint8_t *value;
  size_t value_len;
  uint32_t selection_start, selection_end;
  uint64_t text_revision;
} telar_gui_accessibility_node;

typedef struct {
  uint64_t revision;
  const telar_gui_accessibility_node *nodes;
  uint32_t count;
} telar_gui_accessibility_tree;

// Five vec4 rows in std430 order: rect, uv, fill color, shape (corner radius,
// border width, texture selector, one zero reserved float) and border color.
// Radius and border at zero select the plain textured path; texture 0 samples
// the alpha atlas as coverage, texture 1 the premultiplied RGBA sprite page.
typedef struct {
  float x, y, width, height;
  float u0, v0, u1, v1;
  float r, g, b, a;
  float radius, border, texture, reserved;
  float border_r, border_g, border_b, border_a;
} telar_gui_quad;

typedef struct {
  uint32_t width;
  uint32_t height;
  float scale;
} telar_gui_viewport;

typedef struct {
  // Zero defers submission. The host waits for another wake or viewport change.
  uint64_t token;
  const telar_gui_quad *quads;
  uint32_t quad_count;
  const uint8_t *atlas;
  uint32_t atlas_side;
  uint32_t atlas_version;
  // Premultiplied RGBA8, square; NULL or zero side means no sprites this frame.
  const uint8_t *sprites;
  uint32_t sprites_side;
  uint32_t sprites_version;
  // Straight RGBA; the GPU target stores premultiplied color after blending.
  float background[4];
  uint32_t background_blur;
  uint32_t titlebar;
} telar_gui_frame;

// Input kinds: 1 committed UTF-8 text, 2 clipboard paste, 3 semantic key,
// 4 Unicode key with modifiers, 5 host focus (code=0 inactive, code=1 active),
// 6 pointer: code=press1/release2/drag3/up4/down5/move6/leave7, button=left0/middle1/right2.
// Pointer x/y are physical pixels from the content top-left. Zero physical
// means composed text; otherwise the stable native keycode is stored plus one.
// Key codes: 0 Unicode scalar, then enter, tab, backspace, escape, up,
// down, left, right, home, end, delete, page-up, page-down.
// Modifiers: shift=1, alt=2, ctrl=4; pointer events also carry super=8.
// Phases: press=1, repeat=2, release=3.
typedef struct {
  uint32_t kind, code, mods, phase;
  const uint8_t *text;
  size_t len;
  uint32_t physical, button;
  double x, y;
  // Kind 7: composition update(code=1)/cancel(code=2). text is preedit;
  // selection_* indexes preedit, replacement_* indexes the surrounding text.
  // Kind 1 may also carry replacement_* for an IME commit.
  // Kind 8: scroll, positive dx right/dy down; precise=1 uses device pixels,
  // otherwise line units. phases: none0/begin1/update2/end3/cancel4.
  // Kind 9: clipboard completion: code success0/unavailable1/too_large2/cancelled3.
  // Kind 10: accessibility action: code is one action bit from the node.
  // Kind 11: delete surrounding: replacement_start/end contain before/after byte
  // counts relative to the context's cursor. Applied before commit/preedit.
  uint64_t target_id, request_id, generation;
  uint32_t selection_start, selection_end;
  uint32_t replacement_start, replacement_end;
  double delta_x, delta_y;
  uint32_t precise, scroll_phase, momentum_phase;
  uint64_t revision;
} telar_gui_input;

typedef struct {
  void (*render)(void *, telar_gui_viewport, telar_gui_frame *);
  int (*pump)(void *);
  void (*complete)(void *, uint64_t, int);
  int (*input)(void *, telar_gui_input);
  int wake_fd;
  // Optional one-shot wake deadline in milliseconds. Zero parks the timer.
  uint32_t (*wakeup_after)(void *);
  // Optional, read-only native pointer shape, independent of GPU frames.
  // Values match core.PointerShape (0 default through 33 zoom_out).
  uint32_t (*pointer_shape)(void *);
  // Window-thread callbacks. Copy returned slices before pumping/rendering again.
  // Text contexts follow editing state; accessibility uses delivered geometry.
  // A text_context result of -1 preserves the prior native cache while admitted
  // input awaits dispatch. Zero disables it; positive publishes this snapshot.
  // composition_active is provisional Zig state once all admitted input drained.
  // host_request consumes one request; zero means none. Never call from workers.
  int (*text_context)(void *, telar_gui_text_context *);
  int (*host_request)(void *, telar_gui_host_request *);
  int (*accessibility)(void *, telar_gui_accessibility_tree *);
} telar_gui_callbacks;

int telar_gui_run(const char *title, void *context,
                  const telar_gui_callbacks *callbacks);
int telar_gui_pipe(int *fds);
void telar_gui_wake(int fd);
void telar_gui_drain(int fd);
void telar_gui_close_pipe(int *fds);
void telar_gui_local_time(uint16_t *output);
#endif
