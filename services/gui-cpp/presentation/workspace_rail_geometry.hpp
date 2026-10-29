#pragma once

#include "core/geometry.hpp"
#include "workspace_window.hpp"
#include <algorithm>
#include <cmath>
#include <cstddef>

namespace telar::gui {

struct WorkspaceRailGeometry {
  static constexpr float button_side = 36;
  static constexpr float button_gap = 10;
  static constexpr float inset = 12;
  static constexpr float counter_height = 20;
  static constexpr float edge_width = 1;

  WorkspaceWindow window;
  Rect list;
  Rect previous;
  Rect next;
  float side = 0;
  float gap = 0;
  float mark_top = 0;

  [[nodiscard]] static WorkspaceRailGeometry measure(Rect area, float ratio, WorkspaceWindow::Selection selection) noexcept {
    WorkspaceRailGeometry geometry;
    if (!std::isfinite(ratio) || ratio <= 0 || !std::isfinite(area.x) || !std::isfinite(area.y) || !std::isfinite(area.width) || !std::isfinite(area.height) || area.width <= edge_width || area.height <= 0) {
      return geometry;
    }

    geometry.side = std::min(button_side * ratio, area.width - edge_width);
    geometry.gap = button_gap * ratio;
    const auto vertical_inset = inset * ratio;
    const auto top = area.y + vertical_inset;
    auto remaining = area.y + area.height;
    remaining -= vertical_inset;
    remaining -= top;
    geometry.list = {.x = area.x + std::floor((area.width - edge_width - geometry.side) / 2), .y = top, .width = geometry.side, .height = std::max(0.0F, remaining)};
    if (geometry.list.height <= 0 || geometry.side <= 0) {
      return geometry;
    }

    const auto pitch = geometry.side + geometry.gap;
    const auto bounded_capacity = [total = selection.count](float available) {
      const auto count = std::max(0.0F, std::floor(available));

      return count >= static_cast<float>(total) ? total : static_cast<std::size_t>(count);
    };
    auto capacity = bounded_capacity((geometry.list.height + geometry.gap) / pitch);
    const auto counter = counter_height * ratio;
    const bool counters = capacity < selection.count && geometry.list.height >= geometry.side + (2 * (counter + geometry.gap));
    if (counters) {
      capacity = bounded_capacity((geometry.list.height - (2 * (counter + geometry.gap)) + geometry.gap) / pitch);
    }

    geometry.window = WorkspaceWindow::centered(selection, std::max(std::size_t{1}, capacity));
    geometry.mark_top = geometry.list.y;
    if (counters) {
      geometry.previous = {.x = geometry.list.x, .y = geometry.list.y, .width = geometry.side, .height = counter};
      geometry.mark_top += counter + geometry.gap;
      auto top = geometry.mark_top;
      for (std::size_t position = 0; position < geometry.window.count && top + geometry.side <= geometry.list.bottom(); ++position) {
        top += pitch;
      }

      geometry.next = {.x = geometry.list.x, .y = top, .width = geometry.side, .height = counter};
    }

    return geometry;
  }

  [[nodiscard]] Rect firstMark() const noexcept {
    const Rect bounds{.x = list.x, .y = mark_top, .width = side, .height = side};

    return window.count != 0 && bounds.bottom() <= list.bottom() ? bounds : Rect{};
  }

  [[nodiscard]] Rect nextMark(Rect current) const noexcept {
    current.y += side + gap;

    return current.bottom() <= list.bottom() ? current : Rect{};
  }

};

}
