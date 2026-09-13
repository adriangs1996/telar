#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct {
    const uint8_t *font;
    size_t font_len;
    const char *postscript;
    int32_t face_index;
    uint8_t *pixels;
    uint32_t side;
    uint32_t thicken, strength;
} telar_glyph_rasterizer_options;

typedef struct {
    uint32_t index, style;
    uint32_t x, y, width, height;
    int32_t left, top;
} telar_glyph_raster;

typedef struct telar_glyph_rasterizer telar_glyph_rasterizer;

// Borrowed font bytes and atlas storage outlive the single-owner rasterizer.
telar_glyph_rasterizer *telar_glyph_rasterizer_create(const telar_glyph_rasterizer_options *options);
void telar_glyph_rasterizer_destroy(telar_glyph_rasterizer *self);
int telar_glyph_rasterizer_select(telar_glyph_rasterizer *self, uint32_t pixel_height);
int telar_glyph_rasterizer_measure(telar_glyph_rasterizer *self, telar_glyph_raster *glyph);
void telar_glyph_rasterizer_draw(telar_glyph_rasterizer *self, const telar_glyph_raster *glyph);
