#pragma once

#include "core/geometry.hpp"
#include "input/tab_drag.hpp"
#include "presentation/tab_strip_geometry.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>

namespace telar::gui {

struct TabDropSlot {
  std::uint64_t id = 0;
  Rect bounds;
};

class TabDropSlots {
public:
  static constexpr std::size_t capacity = TabStripGeometry::maximum_tabs;

  void capture(std::span<const TabDropSlot> delivered) noexcept {
    count_ = std::min(delivered.size(), entries_.size());
    std::copy_n(delivered.begin(), count_, entries_.begin());
  }

  [[nodiscard]] std::optional<TabDropTarget> at(TabDrag::Position point) const noexcept {
    const TabDropSlot *nearest = nullptr;
    double distance = std::numeric_limits<double>::infinity();
    double left = std::numeric_limits<double>::infinity();
    double right = -std::numeric_limits<double>::infinity();
    for (const auto &slot : std::span{entries_}.first(count_)) {
      if (point[1] < slot.bounds.y || point[1] >= slot.bounds.y + slot.bounds.height) {
        continue;
      }

      left = std::min(left, static_cast<double>(slot.bounds.x));
      right = std::max(right, static_cast<double>(slot.bounds.x + slot.bounds.width));
      const auto horizontal_distance = std::max({0.0, slot.bounds.x - point[0], point[0] - (slot.bounds.x + slot.bounds.width)});
      if (horizontal_distance < distance) {
        nearest = &slot;
        distance = horizontal_distance;
      }
    }

    if (point[0] < left || point[0] >= right || nearest == nullptr) {
      return std::nullopt;
    }

    return TabDropTarget{.relative_to = nearest->id, .direction = point[0] < nearest->bounds.x + (nearest->bounds.width / 2) ? TabMoveDirection::previous : TabMoveDirection::next};
  }

  [[nodiscard]] std::span<const TabDropSlot> view() const noexcept {
    return std::span{entries_}.first(count_);
  }

private:
  std::array<TabDropSlot, capacity> entries_{};
  std::size_t count_ = 0;
};

}
