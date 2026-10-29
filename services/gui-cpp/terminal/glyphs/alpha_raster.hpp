#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <stdexcept>

namespace telar::gui::glyphs {

struct AlphaRaster {
  std::span<std::uint8_t> pixels;
  std::size_t stride = 0;
  std::uint16_t width = 0;
  std::uint16_t height = 0;

  [[nodiscard]] bool empty() const noexcept {
    return width == 0 || height == 0;
  }

  void validate() const {
    if (empty()) {
      return;
    }

    if (width > stride || pixels.size() < width || static_cast<std::size_t>(height) - 1 > (pixels.size() - width) / stride) {
      throw std::invalid_argument{"InvalidGlyphRaster"};
    }
  }
};

}
