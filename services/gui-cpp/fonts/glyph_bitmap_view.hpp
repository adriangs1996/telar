#pragma once

#include <cstddef>
#include <cstdint>
#include <span>

namespace telar::gui::fonts {

struct GlyphStyle {
  bool bold = false;
  bool italic = false;

  bool operator==(const GlyphStyle &) const = default;
};

struct GlyphRasterRequest {
  std::uint32_t index = 0;
  std::uint16_t pixel_height = 0;
  GlyphStyle style;
};

struct GlyphBitmapView {
  std::span<const std::uint8_t> coverage;
  std::size_t stride = 0;
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::int32_t left = 0;
  std::int32_t top = 0;

  [[nodiscard]] std::span<const std::uint8_t> row(std::size_t index) const noexcept {
    return coverage.subspan(index * stride, width);
  }
};

}
