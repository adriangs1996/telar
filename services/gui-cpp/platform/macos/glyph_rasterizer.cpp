module;

#include <cstddef>
#include <cstdint>
#include <span>
#include "../font.h"
#include <algorithm>
#include <cstring>
#include <memory>
#include "glyph_rasterizer.h"
#include <stdexcept>

module telar.gui.platform.private_file_stamp;

import telar.gui.fonts.face;


namespace telar::gui::platform {

GlyphRasterizer::GlyphRasterizer(std::span<std::uint8_t> pixels, std::span<const std::uint8_t> bytes, const fonts::FontMatch &match, std::uint8_t strength)
    : pixels_(pixels) {
  constexpr std::size_t raster_side = telar_glyph_atlas_max_side;
  if (pixels_.size() < requiredBytes()) {
    throw std::invalid_argument{"NativeGlyphStorageTooSmall"};
  }
  const auto postscript = std::span{match.postscript};
  if (std::ranges::find(postscript, '\0') == postscript.end()) {
    throw std::invalid_argument{"InvalidRasterizerFontName"};
  }

  const telar_glyph_rasterizer_options options{
      .font = bytes.data(),
      .font_len = bytes.size(),
      .postscript = postscript.front() == '\0' ? nullptr : postscript.data(),
      .face_index = std::max(0, match.face_index),
      .pixels = pixels_.data(),
      .side = raster_side,
      .thicken = 1,
      .strength = strength,
      .variation = &match.variation,
  };
  rasterizer_.reset(telarGlyphRasterizerCreate(&options));
  if (!rasterizer_) {
    throw std::runtime_error{"NativeGlyphRasterizerUnavailable"};
  }
}

GlyphRasterizer::~GlyphRasterizer() = default;

std::size_t GlyphRasterizer::requiredBytes() noexcept {
  constexpr std::size_t raster_side = telar_glyph_atlas_max_side;

  return raster_side * raster_side;
}

void GlyphRasterizer::Deleter::operator()(telar_glyph_rasterizer *rasterizer) const noexcept {
  telarGlyphRasterizerDestroy(rasterizer);
}

fonts::GlyphBitmapView GlyphRasterizer::rasterize(fonts::GlyphRasterRequest request) {
  if (telarGlyphRasterizerSelect(rasterizer_.get(), request.pixel_height) != 0) {
    throw std::runtime_error{"NativeGlyphSizeUnavailable"};
  }

  constexpr unsigned italic_shift = 1;
  telar_glyph_raster glyph{
      .index = request.index,
      .style = static_cast<std::uint32_t>(request.style.bold) | (static_cast<std::uint32_t>(request.style.italic) << italic_shift),
      .x = 0,
      .y = 0,
      .width = 0,
      .height = 0,
      .left = 0,
      .top = 0,
  };
  if (telarGlyphRasterizerMeasure(rasterizer_.get(), &glyph) != 0) {
    throw std::runtime_error{"NativeGlyphMeasurementFailed"};
  }

  telarGlyphRasterizerDraw(rasterizer_.get(), &glyph);

  return {.coverage = pixels_, .stride = telar_glyph_atlas_max_side, .width = glyph.width, .height = glyph.height, .left = glyph.left, .top = glyph.top};
}

}
