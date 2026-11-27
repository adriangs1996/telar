module;
#include "telar_ghostty/modes.hpp"
#include <ghostty/vt.h>

export module telar.ghostty.vt;

import std;

// libghostty-vt's C API stays in this global module fragment only; importers reach it through
// these declarations instead.
export {
  using ::GhosttyAllocator;
  using ::GhosttyAllocatorVtable;
  using ::GhosttyCell;
  using ::GhosttyCellContentTag;
  using ::GhosttyCellsView;
  using ::GhosttyCellWide;
  using ::GhosttyClipboardWrite;
  using ::GhosttyClipboardWriteResult;
  using ::GhosttyCodepointsBuffer;
  using ::GhosttyColorRgb;
  using ::GhosttyFormatter;
  using ::GhosttyFormatterScreenExtra;
  using ::GhosttyFormatterTerminalExtra;
  using ::GhosttyFormatterTerminalOptions;
  using ::GhosttyGraphemeBatch;
  using ::GhosttyGridRef;
  using ::GhosttyKey;
  using ::GhosttyKeyEncoder;
  using ::GhosttyKeyEvent;
  using ::GhosttyKittyGraphics;
  using ::GhosttyKittyGraphicsImage;
  using ::GhosttyKittyGraphicsImageData;
  using ::GhosttyKittyGraphicsImageInsert;
  using ::GhosttyKittyGraphicsImageIterator;
  using ::GhosttyKittyGraphicsPlacementData;
  using ::GhosttyKittyGraphicsPlacementIterator;
  using ::GhosttyKittyImageFormat;
  using ::GhosttyMode;
  using ::GhosttyMods;
  using ::GhosttyPoint;
  using ::GhosttyPointCoordinate;
  using ::GhosttyPointTag;
  using ::GhosttyRenderState;
  using ::GhosttyRenderStateColors;
  using ::GhosttyRenderStateCursor;
  using ::GhosttyRenderStateDirty;
  using ::GhosttyRenderStateRowCells;
  using ::GhosttyRenderStateRowIterator;
  using ::GhosttyResult;
  using ::GhosttyRow;
  using ::GhosttyRowSemanticPrompt;
  using ::GhosttySelection;
  using ::GhosttySizeReportSize;
  using ::GhosttyString;
  using ::GhosttyStyle;
  using ::GhosttyStyleColor;
  using ::GhosttyStyleId;
  using ::GhosttySysImage;
  using ::GhosttyTerminal;
  using ::GhosttyTerminalCursorState;
  using ::GhosttyTerminalData;
  using ::GhosttyTerminalModeConfig;
  using ::GhosttyTerminalProgressReport;
  using ::GhosttyTerminalScreen;
  using ::GhosttyTerminalScrollbar;
  using ::GhosttyTerminalScrollViewport;
  using ::GhosttyTrackedGridRef;
  using ::GhosttyWriter;

  using ::ghostty_formatter_format;
  using ::ghostty_formatter_free;
  using ::ghostty_formatter_terminal_new;
  using ::ghostty_free;
  using ::ghostty_grid_ref_cell;
  using ::ghostty_grid_ref_cells;
  using ::ghostty_grid_ref_grapheme_batch;
  using ::ghostty_grid_ref_graphemes;
  using ::ghostty_grid_ref_hyperlink;
  using ::ghostty_grid_ref_row;
  using ::ghostty_grid_ref_style;
  using ::ghostty_key_encoder_encode;
  using ::ghostty_key_encoder_free;
  using ::ghostty_key_encoder_new;
  using ::ghostty_key_encoder_setopt_from_terminal;
  using ::ghostty_key_event_free;
  using ::ghostty_key_event_new;
  using ::ghostty_key_event_set_action;
  using ::ghostty_key_event_set_key;
  using ::ghostty_key_event_set_mods;
  using ::ghostty_key_event_set_unshifted_codepoint;
  using ::ghostty_kitty_graphics_get;
  using ::ghostty_kitty_graphics_image;
  using ::ghostty_kitty_graphics_image_get;
  using ::ghostty_kitty_graphics_image_get_multi;
  using ::ghostty_kitty_graphics_image_ids;
  using ::ghostty_kitty_graphics_image_insert;
  using ::ghostty_kitty_graphics_image_iterator_free;
  using ::ghostty_kitty_graphics_image_iterator_new;
  using ::ghostty_kitty_graphics_image_next;
  using ::ghostty_kitty_graphics_image_remove;
  using ::ghostty_kitty_graphics_loading_abort;
  using ::ghostty_kitty_graphics_placement_anchor;
  using ::ghostty_kitty_graphics_placement_get;
  using ::ghostty_kitty_graphics_placement_get_multi;
  using ::ghostty_kitty_graphics_placement_iterator_free;
  using ::ghostty_kitty_graphics_placement_iterator_new;
  using ::ghostty_kitty_graphics_placement_next;
  using ::ghostty_kitty_graphics_placement_rect;
  using ::ghostty_kitty_graphics_placement_remove;
  using ::ghostty_kitty_graphics_placement_source_rect;
  using ::ghostty_render_state_clean;
  using ::ghostty_render_state_free;
  using ::ghostty_render_state_get;
  using ::ghostty_render_state_new;
  using ::ghostty_render_state_row_cells_free;
  using ::ghostty_render_state_row_cells_get;
  using ::ghostty_render_state_row_cells_new;
  using ::ghostty_render_state_row_cells_select;
  using ::ghostty_render_state_row_get;
  using ::ghostty_render_state_row_iterator_free;
  using ::ghostty_render_state_row_iterator_new;
  using ::ghostty_render_state_row_iterator_next;
  using ::ghostty_render_state_row_iterator_next_dirty;
  using ::ghostty_render_state_update;
  using ::ghostty_row_get;
  using ::ghostty_sys_set;
  using ::ghostty_terminal_cursor_snapshot;
  using ::ghostty_terminal_free;
  using ::ghostty_terminal_get;
  using ::ghostty_terminal_get_multi;
  using ::ghostty_terminal_grid_ref;
  using ::ghostty_terminal_grid_ref_track;
  using ::ghostty_terminal_index;
  using ::ghostty_terminal_new;
  using ::ghostty_terminal_page_bytes;
  using ::ghostty_terminal_point_from_grid_ref;
  using ::ghostty_terminal_reset;
  using ::ghostty_terminal_resize;
  using ::ghostty_terminal_scroll_viewport;
  using ::ghostty_terminal_set;
  using ::ghostty_terminal_vt_write;
  using ::ghostty_terminal_vt_write_ascii;
  using ::ghostty_tracked_grid_ref_free;
  using ::ghostty_tracked_grid_ref_set;
  using ::ghostty_tracked_grid_ref_snapshot;

  using ::GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE;
  using ::GHOSTTY_CELL_CONTENT_BG_COLOR_RGB;
  using ::GHOSTTY_CELL_CONTENT_CODEPOINT;
  using ::GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME;
  using ::GHOSTTY_CELL_WIDE_SPACER_HEAD;
  using ::GHOSTTY_CELL_WIDE_SPACER_TAIL;
  using ::GHOSTTY_CELL_WIDE_WIDE;
  using ::GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED;
  using ::GHOSTTY_FORMATTER_FORMAT_PLAIN;
  using ::GHOSTTY_FORMATTER_FORMAT_VT;
  using ::GHOSTTY_INVALID_VALUE;
  using ::GHOSTTY_KEY_ACTION_PRESS;
  using ::GHOSTTY_KEY_C;
  using ::GHOSTTY_KEY_ENTER;
  using ::GHOSTTY_KEY_ESCAPE;
  using ::GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION;
  using ::GHOSTTY_KITTY_GRAPHICS_DATA_IMAGE_COUNT;
  using ::GHOSTTY_KITTY_GRAPHICS_DATA_IMAGE_ITERATOR;
  using ::GHOSTTY_KITTY_GRAPHICS_DATA_LOADING_BYTES;
  using ::GHOSTTY_KITTY_GRAPHICS_DATA_LOADING_IMAGE_ID;
  using ::GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_COUNT;
  using ::GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR;
  using ::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_COLUMNS;
  using ::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_GRID_REF;
  using ::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID;
  using ::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_INTERNAL;
  using ::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL;
  using ::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID;
  using ::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_ROWS;
  using ::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET;
  using ::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET;
  using ::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z;
  using ::GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN;
  using ::GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR;
  using ::GHOSTTY_KITTY_IMAGE_DATA_FORMAT;
  using ::GHOSTTY_KITTY_IMAGE_DATA_GENERATION;
  using ::GHOSTTY_KITTY_IMAGE_DATA_HEIGHT;
  using ::GHOSTTY_KITTY_IMAGE_DATA_ID;
  using ::GHOSTTY_KITTY_IMAGE_DATA_PLACEMENT_COUNT;
  using ::GHOSTTY_KITTY_IMAGE_DATA_WIDTH;
  using ::GHOSTTY_KITTY_IMAGE_FORMAT_RGB;
  using ::GHOSTTY_KITTY_IMAGE_FORMAT_RGBA;
  using ::GHOSTTY_NO_VALUE;
  using ::GHOSTTY_OUT_OF_MEMORY;
  using ::GHOSTTY_OUT_OF_SPACE;
  using ::GHOSTTY_POINT_TAG_ACTIVE;
  using ::GHOSTTY_POINT_TAG_SCREEN;
  using ::GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR;
  using ::GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
  using ::GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW;
  using ::GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE;
  using ::GHOSTTY_RENDER_STATE_DATA_COLORS;
  using ::GHOSTTY_RENDER_STATE_DATA_CURSOR;
  using ::GHOSTTY_RENDER_STATE_DATA_DIRTY;
  using ::GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR;
  using ::GHOSTTY_RENDER_STATE_DIRTY_FULL;
  using ::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_EXTRA;
  using ::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE;
  using ::GHOSTTY_RENDER_STATE_ROW_DATA_CELLS;
  using ::GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW;
  using ::GHOSTTY_RENDER_STATE_ROW_DATA_GRID_REF;
  using ::GHOSTTY_RENDER_STATE_ROW_DATA_RAW;
  using ::GHOSTTY_ROW_DATA_HYPERLINK;
  using ::GHOSTTY_ROW_DATA_SEMANTIC_PROMPT;
  using ::GHOSTTY_ROW_DATA_WRAP;
  using ::GHOSTTY_ROW_DATA_WRAP_CONTINUATION;
  using ::GHOSTTY_ROW_SEMANTIC_NONE;
  using ::GHOSTTY_ROW_SEMANTIC_PROMPT;
  using ::GHOSTTY_ROW_SEMANTIC_PROMPT_CONTINUATION;
  using ::GHOSTTY_SCROLL_VIEWPORT_BOTTOM;
  using ::GHOSTTY_SCROLL_VIEWPORT_ROW;
  using ::GHOSTTY_STYLE_COLOR_NONE;
  using ::GHOSTTY_STYLE_COLOR_PALETTE;
  using ::GHOSTTY_STYLE_COLOR_RGB;
  using ::GHOSTTY_SUCCESS;
  using ::GHOSTTY_SYS_OPT_DECODE_PNG;
  using ::GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN;
  using ::GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND;
  using ::GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_OVERRIDE;
  using ::GHOSTTY_TERMINAL_DATA_COLOR_CURSOR;
  using ::GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND;
  using ::GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND_OVERRIDE;
  using ::GHOSTTY_TERMINAL_DATA_COLOR_PALETTE;
  using ::GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT;
  using ::GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_OVERRIDES;
  using ::GHOSTTY_TERMINAL_DATA_COLS;
  using ::GHOSTTY_TERMINAL_DATA_CURSOR_IS_DEFAULT;
  using ::GHOSTTY_TERMINAL_DATA_CURSOR_STYLE;
  using ::GHOSTTY_TERMINAL_DATA_CURSOR_X;
  using ::GHOSTTY_TERMINAL_DATA_CURSOR_Y;
  using ::GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS;
  using ::GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS;
  using ::GHOSTTY_TERMINAL_DATA_MODE;
  using ::GHOSTTY_TERMINAL_DATA_MODIFY_OTHER_KEYS_2;
  using ::GHOSTTY_TERMINAL_DATA_MOUSE_SHAPE_NAME;
  using ::GHOSTTY_TERMINAL_DATA_PWD;
  using ::GHOSTTY_TERMINAL_DATA_ROWS;
  using ::GHOSTTY_TERMINAL_DATA_SCROLLBAR;
  using ::GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_BOTTOM;
  using ::GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_LEFT;
  using ::GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_RIGHT;
  using ::GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_TOP;
  using ::GHOSTTY_TERMINAL_DATA_TITLE;
  using ::GHOSTTY_TERMINAL_DATA_TOTAL_ROWS;
  using ::GHOSTTY_TERMINAL_DATA_VT_GROUND;
  using ::GHOSTTY_TERMINAL_DATA_VT_PROCESSING_ERROR;
  using ::GHOSTTY_TERMINAL_OPT_ACTIVE_SCREEN;
  using ::GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES_KITTY;
  using ::GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE;
  using ::GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND;
  using ::GHOSTTY_TERMINAL_OPT_COLOR_CURSOR;
  using ::GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND;
  using ::GHOSTTY_TERMINAL_OPT_COLOR_PALETTE;
  using ::GHOSTTY_TERMINAL_OPT_CURSOR_PENDING_WRAP;
  using ::GHOSTTY_TERMINAL_OPT_CURSOR_X;
  using ::GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK;
  using ::GHOSTTY_TERMINAL_OPT_GLYPH_PROTOCOL;
  using ::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE;
  using ::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM;
  using ::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE;
  using ::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT;
  using ::GHOSTTY_TERMINAL_OPT_KITTY_PROTOCOL;
  using ::GHOSTTY_TERMINAL_OPT_MODE;
  using ::GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT;
  using ::GHOSTTY_TERMINAL_OPT_PWD_CHANGED;
  using ::GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES;
  using ::GHOSTTY_TERMINAL_OPT_SIZE;
  using ::GHOSTTY_TERMINAL_OPT_TITLE_CHANGED;
  using ::GHOSTTY_TERMINAL_OPT_USERDATA;
  using ::GHOSTTY_TERMINAL_OPT_WRITE_PTY;
  using ::GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
  using ::GHOSTTY_TERMINAL_SCREEN_PRIMARY;
}

// Macros do not cross an import. Each constant the tree reads is captured while the header still
// defines it, undefined, and exported under its own name. A mode packs its number in bits 0-14
// and the ANSI flag in bit 15 through ghostty_mode_new, a static inline function that no constant
// expression can call, so the capture packs the same bits. The captures are exported too: an
// importer that also includes the header, as the ghostty-modes test does, can only reach them,
// and that test checks each against the header's ghostty_mode_new.
// NOLINTNEXTLINE(cppcoreguidelines-macro-usage): only the preprocessor can read a constant while the header defines it, and modes.hpp shares the list with the ghostty-modes test.
#define TELAR_GHOSTTY_CONSTANTS(X)       \
  X(GHOSTTY_MODS_CTRL)                   \
  X(GHOSTTY_TELAR_ASCII_CODEPOINT_LIMIT) \
  TELAR_GHOSTTY_MODES(X)

export namespace telar::ghostty {

  // ghostty_mode_new for a mode known only at run time, as a mode report reads it. The captures
  // below pack their bits through it.
  constexpr GhosttyMode mode(std::uint16_t value, bool ansi) noexcept {
    constexpr std::uint32_t number_mask = 0x7FFFU;
    constexpr std::uint32_t ansi_shift = 15U;

    return static_cast<GhosttyMode>((std::uint32_t{value} & number_mask) | (std::uint32_t{ansi} << ansi_shift));
  }

}

export namespace telar::ghostty::captured {

// NOLINTNEXTLINE(cppcoreguidelines-macro-usage): replaces the header's static inline ghostty_mode_new so its mode macros expand to constant expressions.
#define ghostty_mode_new(value, ansi) telar::ghostty::mode(value, ansi)
#define TELAR_GHOSTTY_CAPTURE(name) inline constexpr auto name##_ = name;
  TELAR_GHOSTTY_CONSTANTS(TELAR_GHOSTTY_CAPTURE) // NOLINT(bugprone-signed-bitwise): the header shifts a signed literal in GHOSTTY_MODS_CTRL.
#undef ghostty_mode_new

}

#undef GHOSTTY_MODS_CTRL
#undef GHOSTTY_TELAR_ASCII_CODEPOINT_LIMIT
#undef GHOSTTY_MODE_ALT_SCROLL
#undef GHOSTTY_MODE_ANY_MOUSE
#undef GHOSTTY_MODE_BRACKETED_PASTE
#undef GHOSTTY_MODE_BUTTON_MOUSE
#undef GHOSTTY_MODE_DECCKM
#undef GHOSTTY_MODE_FOCUS_EVENT
#undef GHOSTTY_MODE_KEYPAD_KEYS
#undef GHOSTTY_MODE_NORMAL_MOUSE
#undef GHOSTTY_MODE_REVERSE_COLORS
#undef GHOSTTY_MODE_SGR_MOUSE
#undef GHOSTTY_MODE_SGR_PIXELS_MOUSE
#undef GHOSTTY_MODE_SYNC_OUTPUT
#undef GHOSTTY_MODE_X10_MOUSE

#define TELAR_GHOSTTY_CONSTANT(name) inline constexpr auto name = telar::ghostty::captured::name##_;

export {
  TELAR_GHOSTTY_CONSTANTS(TELAR_GHOSTTY_CONSTANT) // NOLINT(readability-identifier-naming): each constant keeps the name of the header's macro it replaces.
}
