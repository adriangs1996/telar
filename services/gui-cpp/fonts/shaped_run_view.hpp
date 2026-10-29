#pragma once

#include "terminal/font_grid.hpp"
#include <cstddef>
#include <cstdint>
#include <hb.h>
#include <span>

namespace telar::gui::fonts {

struct ShapedGlyph {
  std::uint32_t index = 0;
  std::uint32_t cluster = 0;
  std::int32_t x_advance = 0;
  std::int32_t y_advance = 0;
  std::int32_t x_offset = 0;
  std::int32_t y_offset = 0;

  bool operator==(const ShapedGlyph &) const = default;
};

class ShapedRunView {
public:
  [[nodiscard]] std::size_t size() const noexcept {
    return glyphs_.size();
  }

  [[nodiscard]] bool rightToLeft() const noexcept {
    return right_to_left_;
  }

  [[nodiscard]] ShapedGlyph glyph(std::size_t index) const noexcept {
    const auto &info = glyphs_[index];
    const auto &position = positions_[index];

    return {.index = info.codepoint, .cluster = info.cluster, .x_advance = position.x_advance, .y_advance = position.y_advance, .x_offset = position.x_offset, .y_offset = position.y_offset};
  }

  [[nodiscard]] std::int32_t advance() const {
    std::int64_t advance = 0;
    for (const auto &position : positions_) {
      advance += position.x_advance;
    }

    return FontMetrics::roundFixed(advance);
  }

private:
  friend class Face;

  ShapedRunView(std::span<const hb_glyph_info_t> glyphs, std::span<const hb_glyph_position_t> positions, bool right_to_left) noexcept
      : glyphs_(glyphs),
        positions_(positions),
        right_to_left_(right_to_left) {}

  std::span<const hb_glyph_info_t> glyphs_;
  std::span<const hb_glyph_position_t> positions_;
  bool right_to_left_;
};

}
