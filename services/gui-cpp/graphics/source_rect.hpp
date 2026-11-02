#pragma once

#include "core/geometry.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <cstdint>

namespace telar::gui {

struct ImageSourceRect {
  std::uint32_t x = 0;
  std::uint32_t y = 0;
  std::uint32_t width = 0;
  std::uint32_t height = 0;

  [[nodiscard]] static ImageSourceRect resolve(const GraphicsPlacement &placement, const ImageDescription &image) noexcept {
    const auto left = std::min(placement.source_x, image.width);
    const auto top = std::min(placement.source_y, image.height);
    const auto remaining_width = image.width - left;
    const auto remaining_height = image.height - top;

    return {.x = left, .y = top, .width = placement.source_width == 0 ? remaining_width : std::min(placement.source_width, remaining_width), .height = placement.source_height == 0 ? remaining_height : std::min(placement.source_height, remaining_height)};
  }

  [[nodiscard]] Rect pixels() const noexcept {
    return {.x = static_cast<float>(x), .y = static_cast<float>(y), .width = static_cast<float>(width), .height = static_cast<float>(height)};
  }
};

}
