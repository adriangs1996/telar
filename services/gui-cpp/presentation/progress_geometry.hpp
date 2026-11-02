#pragma once

#include "core/geometry.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <cstddef>

namespace telar::gui {

struct ProgressGeometry {
  static constexpr float ring_side = 14;
  static constexpr float padding = 5;
  static constexpr float height = 20;
  static constexpr float ring_inset = 4;
  static constexpr float background_alpha = 0.1F;
  static constexpr float mark_stroke_ratio = 0.1F;
  static constexpr float mark_top_ratio = 0.32F;
  static constexpr float pause_height_ratio = 0.36F;
  static constexpr float error_height_ratio = 0.24F;
  static constexpr float error_dot_ratio = 0.63F;
  static constexpr std::array pause_offsets{-1.5F, 0.5F};

  Rect background;
  Rect ring;
  std::array<Rect, 2> marks{};
  std::size_t mark_count = 0;
  float mark_radius = 0;

  [[nodiscard]] static constexpr float compactWidth(float ratio = 1) noexcept {
    const auto scaled_padding = padding * ratio;

    return (ring_side * ratio) + (2 * scaled_padding);
  }

  [[nodiscard]] static ProgressGeometry derive(Rect area, float ratio, PaneProgressState state, bool compact = true) noexcept {
    ProgressGeometry geometry;
    const auto capsule_height = std::min(area.height, height * ratio);
    const auto capsule_width = compact ? std::min(area.width, compactWidth(ratio)) : area.width;
    geometry.background = {.x = area.x + area.width - capsule_width, .y = area.y + ((area.height - capsule_height) / 2), .width = capsule_width, .height = capsule_height};
    const auto side = std::max(0.0F, std::min({ring_side * ratio, capsule_height - (ring_inset * ratio), capsule_width - (2 * padding * ratio)}));
    geometry.ring = {.x = geometry.background.x + (padding * ratio), .y = geometry.background.y + ((capsule_height - side) / 2), .width = side, .height = side};
    if (side <= 0) {
      return geometry;
    }

    const auto stroke = std::max(1.0F, side * mark_stroke_ratio);
    const auto center = geometry.ring.x + (side / 2);
    const auto top = geometry.ring.y + (side * mark_top_ratio);
    geometry.mark_radius = stroke / 2;
    if (state == PaneProgressState::pause) {
      for (const auto offset : pause_offsets) {
        geometry.marks[geometry.mark_count++] = {.x = center + (offset * stroke), .y = top, .width = stroke, .height = side * pause_height_ratio};
      }
    } else if (state == PaneProgressState::error) {
      geometry.marks[geometry.mark_count++] = {.x = center - (stroke / 2), .y = top, .width = stroke, .height = side * error_height_ratio};
      geometry.marks[geometry.mark_count++] = {.x = center - (stroke / 2), .y = geometry.ring.y + (side * error_dot_ratio), .width = stroke, .height = stroke};
    }

    return geometry;
  }
};

}
