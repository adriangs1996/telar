#pragma once
#include <stdint.h>

// The largest font file either port reports; the Zig side reads with the same bound.
#define TELAR_FONT_MAX_BYTES (64u << 20)

typedef struct {
    char path[4096];
    char postscript[256];
    int32_t face_index;
} telar_font_match;

// Resolve an installed family without silently substituting another family.
int telar_gui_find_font(const char *family, telar_font_match *match);

// Find an installed face covering one UTF-8 grapheme, preferring monospace.
// Color (sbix/CBDT/COLR), bitmap-only, oversized and last-resort faces are
// skipped; -1 means no usable face covers the text.
int telar_gui_find_fallback_font(const char *text, telar_font_match *match);
