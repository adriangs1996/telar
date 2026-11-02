#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <stdexcept>

namespace telar::gui {

struct AttachmentPreviewBounds {
  std::uint32_t side;
  std::uint32_t pixels;
};

struct AttachmentPreviewSize {
  static constexpr std::uint32_t thumbnail_side = 256;
  static constexpr std::uint32_t full_side = 2048;
  static constexpr std::uint32_t full_pixels = std::uint32_t{2} * 1024 * 1024;

  std::uint32_t width = 0;
  std::uint32_t height = 0;

  [[nodiscard]] static AttachmentPreviewSize fit(std::uint32_t width, std::uint32_t height, AttachmentPreviewBounds bounds) {
    if (width == 0 || height == 0) {
      throw std::invalid_argument{"InvalidClipboardImage"};
    }

    const auto source_width = static_cast<double>(width);
    const auto source_height = static_cast<double>(height);
    const auto side_scale = static_cast<double>(bounds.side) / std::max(source_width, source_height);
    const auto area_scale = std::sqrt(static_cast<double>(bounds.pixels) / (source_width * source_height));
    const auto scale = std::min({1.0, side_scale, area_scale});

    return {.width = std::max(1U, std::min(width, static_cast<std::uint32_t>(std::floor(source_width * scale)))), .height = std::max(1U, std::min(height, static_cast<std::uint32_t>(std::floor(source_height * scale))))};
  }
};

}
