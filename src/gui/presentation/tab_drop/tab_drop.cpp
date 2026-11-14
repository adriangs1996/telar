module telar.gui.presentation.tab_drop;

import std;
import telar.wire.vocabulary;

namespace telar::gui {

  void TabDrag::begin(TabLocation source, Position point) noexcept {
    *this = {};
    captured_ = true;
    source_ = source;
    origin_ = point;
  }

  void TabDrag::cancel() noexcept {
    source_.reset();
    destination_.reset();
    dragging_ = false;
  }

  void TabDrag::validate(std::optional<WorkspaceLocation> workspace, std::span<const std::uint64_t> tabs, bool naming) noexcept {
    if (source_ && (naming || !workspace || workspace->kind != source_->workspace.kind || workspace->id != source_->workspace.id || std::ranges::find(tabs, source_->tab_id) == tabs.end())) {
      cancel();
    }
  }

  void TabDrag::update(Position point, std::optional<TabDropTarget> destination) noexcept {
    if (!source_) {
      return;
    }

    constexpr double threshold = 1;

    dragging_ = dragging_ || std::abs(point[0] - origin_[0]) >= threshold || std::abs(point[1] - origin_[1]) >= threshold;
    destination_ = dragging_ && destination && destination->relative_to != source_->tab_id ? destination : std::nullopt;
  }

  std::optional<TabDragMove> TabDrag::preview() const noexcept {
    if (!source_ || !destination_) {
      return std::nullopt;
    }

    return TabDragMove{.location = *source_, .direction = destination_->direction, .relative_to = destination_->relative_to};
  }

  std::optional<TabDragMove> TabDrag::finish() noexcept {
    const auto result = preview();

    *this = {};

    return result;
  }

  bool TabDrag::captured() const noexcept {
    return captured_;
  }

  bool TabDrag::dragging() const noexcept {
    return dragging_;
  }

  const std::optional<TabLocation>& TabDrag::source() const noexcept {
    return source_;
  }

  const std::optional<TabDropTarget>& TabDrag::destination() const noexcept {
    return destination_;
  }

  void TabDropSlots::capture(std::span<const TabDropSlot> delivered) noexcept {
    count_ = std::min(delivered.size(), entries_.size());
    std::copy_n(delivered.begin(), count_, entries_.begin());
  }

  std::optional<TabDropTarget> TabDropSlots::at(TabDrag::Position point) const noexcept {
    const TabDropSlot* nearest = nullptr;
    double distance = std::numeric_limits<double>::infinity();
    double left = std::numeric_limits<double>::infinity();
    double right = -std::numeric_limits<double>::infinity();

    for (const auto& slot : std::span{entries_}.first(count_)) {
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

  std::span<const TabDropSlot> TabDropSlots::view() const noexcept {
    return std::span{entries_}.first(count_);
  }

  const TabDropSlot* TabDropSurface::at(TabDrag::Position point) const noexcept {
    const auto contains = [&](const Rect& bounds) {
      return point[0] >= bounds.x && point[0] < bounds.right() && point[1] >= bounds.y && point[1] < bounds.bottom();
    };
    if (contains(create)) {
      return nullptr;
    }

    for (const auto& target : std::span{targets}.first(count) | std::views::reverse) {
      if (contains(target.bounds)) {
        return &target;
      }
    }

    return nullptr;
  }

  std::span<const TabDropSlot> TabDropSurface::view() const noexcept {
    return std::span{targets}.first(count);
  }

}
