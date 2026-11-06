#pragma once

#include "core/geometry.hpp"
#include "pane_decoration_geometry.hpp"
#include <algorithm>

namespace telar::gui {

struct PaneAttentionGeometry {
  static constexpr float line_width = 2;
  static constexpr float inset_pixels = 1;

  Rect bounds;
  float width = 0;
  float radius = 0;

  [[nodiscard]] static PaneAttentionGeometry derive(Rect physical_frame, float physical_ratio, float logical_radius = PaneDecorationGeometry::frame_radius) noexcept {
    return {
        .bounds = physical_frame.inset(inset_pixels, inset_pixels),
        .width = line_width * physical_ratio,
        .radius = std::max(0.0F, (logical_radius * physical_ratio) - inset_pixels),
    };
  }
};

}
