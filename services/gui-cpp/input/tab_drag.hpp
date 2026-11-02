#pragma once

#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <optional>
#include <span>

namespace telar::gui {

struct TabDropTarget {
  std::optional<std::uint64_t> relative_to;
  TabMoveDirection direction = TabMoveDirection::previous;
};

struct TabDragMove {
  TabLocation location;
  TabMoveDirection direction = TabMoveDirection::previous;
  std::optional<std::uint64_t> relative_to;
};

class TabDrag {
public:
  using Position = std::array<double, 2>;
  static constexpr double logical_threshold = 4;

  void begin(TabLocation source, Position point) noexcept {
    *this = {};
    captured_ = true;
    source_ = source;
    origin_ = point;
  }

  void cancel() noexcept {
    source_.reset();
    destination_.reset();
    dragging_ = false;
  }

  void validate(std::optional<WorkspaceLocation> workspace, std::span<const std::uint64_t> tabs, bool naming) noexcept {
    if (source_ && (naming || !workspace || workspace->kind != source_->workspace.kind || workspace->id != source_->workspace.id || std::ranges::find(tabs, source_->tab_id) == tabs.end())) {
      cancel();
    }
  }

  void update(Position point, std::optional<TabDropTarget> destination) noexcept {
    if (!source_) {
      return;
    }

    constexpr double threshold = 1;
    dragging_ = dragging_ || std::abs(point[0] - origin_[0]) >= threshold || std::abs(point[1] - origin_[1]) >= threshold;
    destination_ = dragging_ && destination && destination->relative_to != source_->tab_id ? destination : std::nullopt;
  }

  [[nodiscard]] std::optional<TabDragMove> preview() const noexcept {
    if (!source_ || !destination_) {
      return std::nullopt;
    }

    return TabDragMove{.location = *source_, .direction = destination_->direction, .relative_to = destination_->relative_to};
  }

  [[nodiscard]] std::optional<TabDragMove> finish() noexcept {
    const auto result = preview();
    *this = {};

    return result;
  }

  [[nodiscard]] bool captured() const noexcept {
    return captured_;
  }

  [[nodiscard]] bool dragging() const noexcept {
    return dragging_;
  }

  [[nodiscard]] const std::optional<TabLocation> &source() const noexcept {
    return source_;
  }

  [[nodiscard]] const std::optional<TabDropTarget> &destination() const noexcept {
    return destination_;
  }

private:
  bool captured_ = false;
  std::optional<TabLocation> source_;
  Position origin_{};
  bool dragging_ = false;
  std::optional<TabDropTarget> destination_;
};

}
