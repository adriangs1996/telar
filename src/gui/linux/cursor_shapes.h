#pragma once
#include "cursor-shape-v1-client-protocol.h"

#define TELAR_CURSOR_SHAPES 34

// Indexed by core.PointerShape, whose resize order differs from Wayland's.
static const struct {
    uint32_t protocol;
    const char *name, *alias;
} telar_cursor_shapes[TELAR_CURSOR_SHAPES] = {
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT, "default", "left_ptr"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_CONTEXT_MENU, "context-menu", "left_ptr"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_HELP, "help", "question_arrow"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_POINTER, "pointer", "hand2"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_PROGRESS, "progress", "left_ptr_watch"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_WAIT, "wait", "watch"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_CELL, "cell", "plus"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_CROSSHAIR, "crosshair", "cross"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_TEXT, "text", "xterm"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_VERTICAL_TEXT, "vertical-text", "xterm"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ALIAS, "alias", "dnd-link"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_COPY, "copy", "dnd-copy"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_MOVE, "move", "fleur"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NO_DROP, "no-drop", "dnd-no-drop"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NOT_ALLOWED, "not-allowed", "crossed_circle"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_GRAB, "grab", "hand1"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_GRABBING, "grabbing", "closedhand"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ALL_SCROLL, "all-scroll", "fleur"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_COL_RESIZE, "col-resize", "sb_h_double_arrow"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ROW_RESIZE, "row-resize", "sb_v_double_arrow"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_N_RESIZE, "n-resize", "top_side"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_E_RESIZE, "e-resize", "right_side"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_S_RESIZE, "s-resize", "bottom_side"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_W_RESIZE, "w-resize", "left_side"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NE_RESIZE, "ne-resize", "top_right_corner"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NW_RESIZE, "nw-resize", "top_left_corner"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_SE_RESIZE, "se-resize", "bottom_right_corner"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_SW_RESIZE, "sw-resize", "bottom_left_corner"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_EW_RESIZE, "ew-resize", "sb_h_double_arrow"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NS_RESIZE, "ns-resize", "sb_v_double_arrow"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NESW_RESIZE, "nesw-resize", "fd_double_arrow"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NWSE_RESIZE, "nwse-resize", "bd_double_arrow"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ZOOM_IN, "zoom-in", "left_ptr"},
    {WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ZOOM_OUT, "zoom-out", "left_ptr"},
};
