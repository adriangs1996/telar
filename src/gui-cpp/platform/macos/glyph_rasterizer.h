#pragma once
#include "platform/font.h"
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef __cplusplus
enum class TelarGlyphLimits {
#else
enum TelarGlyphLimits {
#endif
  telar_glyph_atlas_max_side = 2048,
};

#ifdef __cplusplus
inline constexpr auto telar_glyph_atlas_max_side = static_cast<uint32_t>(TelarGlyphLimits::telar_glyph_atlas_max_side);
#endif

typedef struct {
  const uint8_t *font;
  size_t font_len;
  const char *postscript;
  int32_t face_index;
  uint8_t *pixels;
  uint32_t side;
  uint32_t thicken, strength;
  const telar_font_variation *variation;
} telar_glyph_rasterizer_options;

typedef struct {
  uint32_t index, style;
  uint32_t x, y, width, height;
  int32_t left, top;
} telar_glyph_raster;

typedef struct telar_glyph_rasterizer telar_glyph_rasterizer;

// Borrowed font bytes and atlas storage outlive the single-owner rasterizer.
telar_glyph_rasterizer *telarGlyphRasterizerCreate(const telar_glyph_rasterizer_options *options);
void telarGlyphRasterizerDestroy(telar_glyph_rasterizer *self);
int telarGlyphRasterizerSelect(telar_glyph_rasterizer *self, uint32_t pixel_height);
int telarGlyphRasterizerMeasure(telar_glyph_rasterizer *self, telar_glyph_raster *glyph);
void telarGlyphRasterizerDraw(telar_glyph_rasterizer *self, const telar_glyph_raster *glyph);

#ifdef __cplusplus
}
#endif
