#pragma once
#include <stdint.h>

// The largest font file either port reports; the Zig side reads with the same bound.
#define TELAR_FONT_MAX_BYTES (64u << 20)

// Variation axes one match carries; a face with more is refused, never truncated.
#define TELAR_FONT_MAX_AXES 16

// Design coordinates for the axes that differ from the face's defaults, so a
// variable font's named instance (wght=350 for "SemiLight") is rasterized
// without trusting either platform's instance naming.
typedef struct {
    uint32_t count;
    uint32_t tags[TELAR_FONT_MAX_AXES];
    float values[TELAR_FONT_MAX_AXES];
} telar_font_variation;

typedef struct {
    char path[4096];
    char postscript[256];
    int32_t face_index;
    telar_font_variation variation;
} telar_font_match;

enum {
    TELAR_FONT_FOUND = 0,
    TELAR_FONT_FAMILY_NOT_FOUND = -1,
    TELAR_FONT_STYLE_NOT_FOUND = -2,
};

// Resolve an installed family and, when `style` is not empty, the face whose
// advertised style name matches it, without silently substituting either.
int telar_gui_find_font(const char *family, const char *style, telar_font_match *match);

// Find an installed face covering one UTF-8 grapheme, preferring monospace.
// Color (sbix/CBDT/COLR), bitmap-only, oversized and last-resort faces are
// skipped; -1 means no usable face covers the text.
int telar_gui_find_fallback_font(const char *text, telar_font_match *match);
