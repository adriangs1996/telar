#pragma once
#include <stdint.h>

typedef struct {
    char path[4096];
    char postscript[256];
    int32_t face_index;
} telar_font_match;

// Resolve an installed family without silently substituting another family.
int telar_gui_find_font(const char *family, telar_font_match *match);
