#pragma once

#include "fonts/glyph_bitmap_view.hpp"
#include "fonts/native_match.hpp"
#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>

extern "C" {
struct telar_glyph_rasterizer;
}

namespace telar::gui::platform {

class GlyphRasterizer final {
public:
  GlyphRasterizer(std::span<std::uint8_t> pixels, std::span<const std::uint8_t> bytes, const fonts::FontMatch &match, std::uint8_t strength);
  ~GlyphRasterizer();
  GlyphRasterizer(const GlyphRasterizer &) = delete;
  GlyphRasterizer &operator=(const GlyphRasterizer &) = delete;
  GlyphRasterizer(GlyphRasterizer &&) = delete;
  GlyphRasterizer &operator=(GlyphRasterizer &&) = delete;

  [[nodiscard]] fonts::GlyphBitmapView rasterize(fonts::GlyphRasterRequest request);
  [[nodiscard]] static std::size_t requiredBytes() noexcept;

private:
  struct Deleter {
    void operator()(telar_glyph_rasterizer *rasterizer) const noexcept;
  };

  std::span<std::uint8_t> pixels_;
  std::unique_ptr<telar_glyph_rasterizer, Deleter> rasterizer_;
};

}
