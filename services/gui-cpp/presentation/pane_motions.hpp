#pragma once

#include "application/pane_layout.hpp"
#include "core/geometry.hpp"
#include "presentation/tab_motion_frame.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>

namespace telar::gui {

struct PaneMotionSlot {
  std::uint64_t id = 0;
  Rect bounds;
};

// Layout targets are committed once. Only presentation rectangles move.
class PaneMotions {
public:
  static constexpr std::uint64_t opening_ns = 180'000'000;
  static constexpr std::uint64_t closing_ns = 150'000'000;

  void update(std::span<const PaneMotionSlot> placements, std::uint64_t now_ns, bool immediate = false) noexcept {
    if (placements.size() > entries_.size()) {
      count_ = 0;
      return;
    }

    bool shared = false;
    bool unchanged = placements.size() == count_;
    for (const auto &slot : placements) {
      const auto *old = find(slot.id);
      shared |= old != nullptr;
      unchanged &= old != nullptr && old->to == slot.bounds;
    }
    if (unchanged && !immediate) {
      return;
    }

    const bool animate = !immediate && shared && placements.size() != count_;
    const auto duration = placements.size() > count_ ? opening_ns : closing_ns;
    std::array<Motion, PaneLayout::maximum_panes> next;
    for (std::size_t index = 0; index < placements.size(); ++index) {
      const auto &slot = placements[index];
      const auto *old = find(slot.id);
      auto from = slot.bounds;
      if (animate) {
        from = old != nullptr ? old->value(now_ns) : entrance(slot.bounds);
      }
      next[index] = {.id = slot.id, .from = from, .to = slot.bounds, .started = now_ns, .duration = from == slot.bounds ? 0 : duration};
    }
    std::copy_n(next.begin(), placements.size(), entries_.begin());
    count_ = placements.size();
  }

  [[nodiscard]] Rect place(std::size_t index, TabMotionFrame &frame) const noexcept {
    const auto &entry = entries_[index];
    frame.request(entry.started, entry.duration);
    return entry.value(frame.now_ns);
  }

private:
  struct Motion {
    std::uint64_t id = 0;
    Rect from;
    Rect to;
    std::uint64_t started = 0;
    std::uint64_t duration = 0;

    [[nodiscard]] Rect value(std::uint64_t now_ns) const noexcept {
      if (duration == 0 || (now_ns >= started && now_ns - started >= duration)) {
        return to;
      }
      const float phase = now_ns <= started ? 0 : static_cast<float>(now_ns - started) / static_cast<float>(duration);
      const float remaining = 1 - phase;
      const float eased = 1 - remaining * remaining * remaining;
      return {.x = from.x + (to.x - from.x) * eased, .y = from.y + (to.y - from.y) * eased, .width = from.width + (to.width - from.width) * eased, .height = from.height + (to.height - from.height) * eased};
    }
  };

  [[nodiscard]] const Motion *find(std::uint64_t id) const noexcept {
    const auto entries = std::span{entries_}.first(count_);
    const auto found = std::ranges::find(entries, id, &Motion::id);
    return found == entries.end() ? nullptr : &*found;
  }

  [[nodiscard]] Rect entrance(Rect target) const noexcept {
    // The added leaf occupies part of its previous parent. Reveal it from
    // the far edge while the surviving leaf moves the shared divider.
    const Motion *parent = nullptr;
    float best_overlap = 0;
    for (const auto &entry : std::span{entries_}.first(count_)) {
      const auto &bounds = entry.to;
      const auto overlap = bounds.intersect(target);
      if (overlap.width * overlap.height > best_overlap) {
        best_overlap = overlap.width * overlap.height;
        parent = &entry;
      }
    }
    if (parent == nullptr) {
      return target;
    }
    const auto &bounds = parent->to;
    if (target.width / bounds.width < target.height / bounds.height) {
      target.x = target.right();
      target.width = 0;
    } else {
      target.y = target.bottom();
      target.height = 0;
    }
    return target;
  }

  std::array<Motion, PaneLayout::maximum_panes> entries_{};
  std::size_t count_ = 0;
};

}
