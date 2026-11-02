#pragma once

#include "core/color.hpp"
#include "core/geometry.hpp"
#include "presentation/progress_geometry.hpp"
#include "progress_ring.hpp"
#include "rounded_rectangle.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <cstddef>

namespace telar::gui {

struct ProgressCapsule {
  static constexpr std::size_t maximum_paints = ProgressRing::maximum_paints + 3;
  Rect area;
  Color color;
  float ratio = 1;
  PaneProgressState state = PaneProgressState::remove;
  float fraction = 0;
  float rotation = 0;
  bool compact = true;

  template <typename Visitor>
  void visit(Visitor append) const {
    if (state == PaneProgressState::remove || area.empty()) {
      return;
    }

    const auto geometry = ProgressGeometry::derive(area, ratio, state, compact);
    const auto bounds = geometry.background;
    auto background = color;
    background.a *= ProgressGeometry::background_alpha;
    append(RoundedRectanglePaint{.origin = {.x = bounds.x, .y = bounds.y}, .shape = RoundedRectangle::resolve({.x = bounds.width, .y = bounds.height}, {.fill = background, .radius = bounds.height / 2})});
    if (geometry.ring.width <= 0) {
      return;
    }

    ProgressRing{.area = geometry.ring, .color = color, .fraction = fraction, .rotation = rotation}.visit(append);
    for (std::size_t index = 0; index < geometry.mark_count; ++index) {
      const auto mark = geometry.marks[index];
      append(RoundedRectanglePaint{.origin = {.x = mark.x, .y = mark.y}, .shape = RoundedRectangle::resolve({.x = mark.width, .y = mark.height}, {.fill = color, .radius = geometry.mark_radius})});
    }
  }
};

}
