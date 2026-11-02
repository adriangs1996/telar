#pragma once

#include "core/configuration.hpp"
#include "core/geometry.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>

namespace telar::gui {

struct FontMetrics {
  std::int32_t ascender = 0;
  std::uint32_t line_height = 1;
  std::uint16_t maximum_advance = 1;
  float box_stroke = 1;

  [[nodiscard]] static std::int32_t roundFixed(std::int64_t value) {
    constexpr std::int64_t fixed_unit = 64;
    constexpr auto rounding_threshold = fixed_unit / 2;
    const auto integral = value / fixed_unit;
    const auto fraction = value % fixed_unit;
    const auto rounded = integral + (fraction >= rounding_threshold ? 1 : 0) - (fraction <= -rounding_threshold ? 1 : 0);
    if (rounded < std::numeric_limits<std::int32_t>::min() || rounded > std::numeric_limits<std::int32_t>::max()) {
      throw std::out_of_range{"FontMetricOutOfRange"};
    }

    return static_cast<std::int32_t>(rounded);
  }
};

struct FontGrid {
  std::uint16_t width = 1;
  std::uint16_t height = 1;
  std::uint16_t pixel_height = 1;
  float baseline = 0;
  float box_stroke = 1;

  [[nodiscard]] static std::uint16_t pixelHeight(const FontConfiguration &font, float scale) {
    if (!std::isfinite(scale) || scale <= 0 || scale > Viewport::maximum_scale) {
      throw std::invalid_argument{"InvalidDisplayScale"};
    }

    const auto height = std::round(font.size * scale);
    if (!std::isfinite(height) || height < 1 || height > std::numeric_limits<std::uint16_t>::max()) {
      throw std::invalid_argument{"InvalidPixelHeight"};
    }

    return static_cast<std::uint16_t>(height);
  }

  [[nodiscard]] static FontGrid resolve(const FontMetrics &metrics, const FontConfiguration &font, float scale) {
    const auto pixels = pixelHeight(font, scale);
    const auto natural_height = static_cast<float>(metrics.line_height);
    const auto height = std::round(natural_height * font.line_height);
    const auto spacing = font.letter_spacing * scale;
    const auto width = std::round(static_cast<float>(metrics.maximum_advance) + spacing);
    constexpr auto maximum_extent = std::numeric_limits<std::uint16_t>::max();
    if (!std::isfinite(width) || !std::isfinite(height) || width < 1 || height < 1 || width > maximum_extent || height > maximum_extent) {
      throw std::invalid_argument{"InvalidFontSpacing"};
    }

    const auto leading = (height - natural_height) / 2;

    return {.width = static_cast<std::uint16_t>(width), .height = static_cast<std::uint16_t>(height), .pixel_height = pixels, .baseline = static_cast<float>(metrics.ascender) + leading, .box_stroke = metrics.box_stroke};
  }
};

}
