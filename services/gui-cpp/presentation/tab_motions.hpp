#pragma once

#include "core/geometry.hpp"
#include "presentation/tab_motion_frame.hpp"
#include "presentation/tab_strip_geometry.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace telar::gui {

struct TabMotionSlot {
  std::uint64_t id = 0;
  Rect bounds;
  bool immediate = false;
};

struct TabMotion {
  static constexpr std::uint64_t duration_ns = 180'000'000;
  std::uint64_t id = 0;
  Rect from;
  Rect to;
  std::uint64_t started = 0;
  std::uint64_t duration = 0;
  bool seen = true;

  [[nodiscard]] Rect value(std::uint64_t now_ns) const noexcept {
    float progress = 1;
    if (now_ns < started) {
      progress = 0;
    } else if (duration != 0 && now_ns - started < duration) {
      progress = static_cast<float>(now_ns - started) / static_cast<float>(duration);
    }
    const float remaining = 1 - progress;
    const float eased = 1 - (remaining * remaining * remaining);

    return {.x = from.x + ((to.x - from.x) * eased), .y = from.y + ((to.y - from.y) * eased), .width = from.width + ((to.width - from.width) * eased), .height = from.height + ((to.height - from.height) * eased)};
  }

  [[nodiscard]] Rect place(Rect bounds, TabMotionFrame &frame, bool immediate = false) noexcept {
    if (immediate) {
      from = bounds;
      to = bounds;
      duration = 0;
      return bounds;
    }
    if (to != bounds) {
      from = value(frame.now_ns);
      to = bounds;
      started = frame.now_ns;
      duration = duration_ns;
    }
    frame.request(started, duration);
    return value(frame.now_ns);
  }
};

class TabMotions {
public:
  static constexpr std::uint64_t duration_ns = TabMotion::duration_ns;

  void begin(std::optional<WorkspaceLocation> workspace) noexcept {
    if (workspace_.has_value() != workspace.has_value() || (workspace_ && (workspace_->kind != workspace->kind || workspace_->id != workspace->id))) {
      count_ = 0;
      workspace_ = workspace;
    }
    for (auto &motion : std::span{entries_}.first(count_)) {
      motion.seen = false;
    }
  }

  [[nodiscard, gnu::always_inline]] Rect place(TabMotionSlot slot, TabMotionFrame &frame) noexcept {
    if (slot.immediate && count_ == 1 && entries_[0].id == slot.id) {
      entries_[0].seen = true;
      entries_[0].from = slot.bounds;
      entries_[0].to = slot.bounds;
      entries_[0].duration = 0;
      return slot.bounds;
    }
    for (auto &motion : std::span{entries_}.first(count_)) {
      if (motion.id != slot.id) {
        continue;
      }

      motion.seen = true;
      return motion.place(slot.bounds, frame, slot.immediate);
    }

    if (count_ < entries_.size()) {
      entries_[count_++] = {.id = slot.id, .from = slot.bounds, .to = slot.bounds, .started = frame.now_ns};
    }

    return slot.bounds;
  }

  void finish() noexcept {
    if (count_ == 1 && entries_[0].seen) {
      return;
    }
    std::size_t kept = 0;
    for (std::size_t index = 0; index < count_; ++index) {
      const auto &motion = entries_[index];
      if (motion.seen) {
        if (kept != index) {
          entries_[kept] = motion;
        }
        ++kept;
      }
    }
    count_ = kept;
  }

  [[nodiscard]] std::size_t size() const noexcept {
    return count_;
  }

private:
  std::array<TabMotion, TabStripGeometry::maximum_tabs> entries_{};
  std::size_t count_ = 0;
  std::optional<WorkspaceLocation> workspace_;
};

}
