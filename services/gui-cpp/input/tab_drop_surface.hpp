#pragma once

#include "input/tab_drop_slots.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <ranges>
#include <span>

namespace telar::gui {

struct TabDropSurface {
  std::array<TabDropSlot, TabDropSlots::capacity> targets{};
  std::size_t count = 0;
  WorkspaceLocation workspace;
  Rect viewport;
  Rect create;
  std::uint64_t machine_view = 0;
  double scale = 1;
  double threshold = TabDrag::logical_threshold;

  [[nodiscard]] const TabDropSlot *at(TabDrag::Position point) const noexcept {
    const auto contains = [&](const Rect &bounds) {
      return point[0] >= bounds.x && point[0] < bounds.right() && point[1] >= bounds.y && point[1] < bounds.bottom();
    };
    if (contains(create)) {
      return nullptr;
    }
    for (const auto &target : std::span{targets}.first(count) | std::views::reverse) {
      if (contains(target.bounds)) {
        return &target;
      }
    }
    return nullptr;
  }

  [[nodiscard]] std::span<const TabDropSlot> view() const noexcept {
    return std::span{targets}.first(count);
  }
};

}
