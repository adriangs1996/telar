#pragma once

#include "core/geometry.hpp"
#include "core/memory.hpp"
#include "face.hpp"
#include "font_role.hpp"
#include "font_runs.hpp"
#include "glyph_transform.hpp"
#include "ink_bounds.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::gui::fonts {

struct IconGlyph {
  std::uint32_t index = 0;
  FontRole face = FontRole::regular;
  Rect ink;
};

struct IconRequest {
  std::uint16_t pixel_height = 0;
  FontRole preferred = FontRole::regular;
};

template <Allocator Memory>
class IconLayout {
public:
  static constexpr std::size_t maximum_text_bytes = 256;
  static constexpr std::size_t maximum_glyphs = 256;
  static constexpr float size_ratio = 0.85F;
  static constexpr std::uint16_t oversample = 2;
  static constexpr std::uint16_t maximum_pixel_height = 4096;

  explicit IconLayout(Memory &memory)
      : glyphs_(AllocatorRef<IconGlyph, Memory>{memory}) {}

  [[nodiscard]] std::span<const IconGlyph> glyphs() const noexcept {
    return glyphs_;
  }

  [[nodiscard]] Rect ink() const noexcept {
    InkBounds bounds;
    for (const auto &glyph : glyphs_) {
      bounds.include(glyph.ink);
    }

    return bounds.rect();
  }

  template <CascadingFontProvider Fonts>
  void shape(Fonts &fonts, std::string_view text, IconRequest request) {
    if (text.size() > maximum_text_bytes || request.pixel_height == 0 || request.pixel_height > maximum_pixel_height) {
      throw std::invalid_argument{"InvalidIconLayoutRequest"};
    }

    glyphs_.clear();
    FontRuns runs{fonts, text, request.preferred};
    float advance = 0;
    while (const auto span = runs.next()) {
      if (!span->role) {
        throw std::runtime_error{"IconFontUnavailable"};
      }

      advance += appendRun(fonts, span->text, {.role = *span->role, .request = request, .columns = span->columns, .advance = advance});
    }
  }

private:
  struct Run {
    FontRole role = FontRole::regular;
    IconRequest request;
    std::uint32_t columns = 0;
    float advance = 0;
  };

  template <CascadingFontProvider Fonts>
  float appendRun(Fonts &fonts, std::string_view text, Run run) {
    auto &face = fonts.face(run.role);
    const auto shaped = face.shape(text, run.request.pixel_height);
    const auto start = glyphs_.size();
    std::int64_t pen = 0;
    for (std::size_t index = 0; index < shaped.size(); ++index) {
      const auto glyph = shaped.glyph(index);
      const auto bitmap = face.rasterize({.index = glyph.index, .pixel_height = run.request.pixel_height, .style = {}});
      if (bitmap.width != 0 && bitmap.height != 0) {
        if (glyphs_.size() == maximum_glyphs) {
          throw std::length_error{"IconGlyphLimitExceeded"};
        }

        const auto x = FontMetrics::roundFixed(pen + glyph.x_offset) + bitmap.left;
        const auto y = -FontMetrics::roundFixed(glyph.y_offset) - bitmap.top;
        glyphs_.push_back({.index = glyph.index, .face = run.role, .ink = {.x = static_cast<float>(x), .y = static_cast<float>(y), .width = static_cast<float>(bitmap.width), .height = static_cast<float>(bitmap.height)}});
      }

      pen += glyph.x_advance;
    }

    auto appended = std::span{glyphs_}.subspan(start);
    if (fittedFont(run.role)) {
      const auto metrics = fonts.face(FontRole::primary).metrics(run.request.pixel_height);
      const Rect cell{.y = -static_cast<float>(metrics.ascender), .width = static_cast<float>(metrics.maximum_advance) * static_cast<float>(run.columns), .height = static_cast<float>(metrics.line_height)};
      fitFallback(appended, cell, run.advance);

      return cell.width;
    }

    for (auto &glyph : appended) {
      glyph.ink.x += run.advance;
    }

    return static_cast<float>(FontMetrics::roundFixed(pen));
  }

  static void fitFallback(std::span<IconGlyph> glyphs, Rect cell, float advance) {
    InkBounds bounds;
    for (const auto &glyph : glyphs) {
      bounds.include(glyph.ink);
    }

    const auto ink = bounds.rect();
    if (ink.empty()) {
      return;
    }

    const auto transform = GlyphTransform::fit(ink, cell);
    for (auto &glyph : glyphs) {
      glyph.ink = {.x = advance + (glyph.ink.x * transform.scale) + transform.x, .y = (glyph.ink.y * transform.scale) + transform.y, .width = glyph.ink.width * transform.scale, .height = glyph.ink.height * transform.scale};
    }
  }

  Vector<IconGlyph, Memory> glyphs_;
};

}
