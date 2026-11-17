module telar.gui.features.workbench;

import std;
import telar.wire.vocabulary;
import telar.gui.foundation.core;

namespace telar::gui::features::workbench {

  auto TabStripGeometry::Metrics::scaled(float ratio) noexcept -> Metrics {
    return {
        .leading = TabStripGeometry::leading * ratio,
        .trailing = TabStripGeometry::trailing * ratio,
        .spacing = TabStripGeometry::spacing * ratio,
        .gap = TabStripGeometry::gap * ratio,
        .inactive_maximum = TabStripGeometry::inactive_maximum * ratio,
        .selected_maximum = TabStripGeometry::selected_maximum * ratio,
        .caption_minimum = TabStripGeometry::caption_minimum * ratio,
        .counter = TabStripGeometry::counter_width * ratio,
    };
  }

  float TabStripGeometry::Measure::statusSpace(const Metrics& metrics) const noexcept {
    return status > 0 ? metrics.spacing + status : 0;
  }

  float TabStripGeometry::Measure::whole(const Metrics& metrics) const noexcept {
    return metrics.leading + chip + metrics.spacing + caption + statusSpace(metrics) + metrics.trailing;
  }

  float TabStripGeometry::Measure::truncated(const Metrics& metrics) const noexcept {
    return std::min(whole(metrics), metrics.leading + chip + metrics.spacing + metrics.caption_minimum + statusSpace(metrics) + metrics.trailing);
  }

  float TabStripGeometry::Measure::compact(const Metrics& metrics) const noexcept {
    return (2 * metrics.leading) + chip + statusSpace(metrics);
  }

  std::size_t TabStripGeometry::Plan::hidden() const noexcept {
    return count - (end - first);
  }

  bool TabStripGeometry::Plan::shows(std::size_t index) const noexcept {
    return index >= first && index < end;
  }

  std::optional<std::size_t> TabStripGeometry::Plan::nearestHidden() const noexcept {
    if (hidden() == 0) {
      return std::nullopt;
    }

    const auto left = first > 0 ? focus - (first - 1) : std::numeric_limits<std::size_t>::max();
    const auto right = end < count ? end - focus : std::numeric_limits<std::size_t>::max();

    return left <= right ? first - 1 : end;
  }

  float TabStripGeometry::Plan::footprint(const Metrics& metrics) const noexcept {
    if (first == end) {
      return 0;
    }

    float used = 0;

    for (auto index = first; index < end; ++index) {
      used += widths[index];
    }

    const auto gaps = metrics.gap * static_cast<float>(end - first - 1);

    used += gaps;
    if (hidden() != 0) {
      used += metrics.gap + metrics.counter;
    }

    return used;
  }

  auto TabStripGeometry::arrange(std::span<const Measure> sizes, std::size_t focus, const Room& room) noexcept -> Plan {
    if (sizes.empty() || sizes.size() > maximum_tabs || focus >= sizes.size() || !std::isfinite(room.width) || room.width < 0) {
      return {};
    }

    const auto& metrics = room.metrics;
    Plan result{.first = 0, .end = sizes.size(), .focus = focus, .count = sizes.size()};
    const auto gaps = metrics.gap * static_cast<float>(sizes.size() - 1);
    // Equal tabs keep the row still while the selection slides across it.
    const auto equal = std::floor((room.width - gaps) / static_cast<float>(sizes.size()));
    if (std::ranges::all_of(sizes, [&](const Measure& size) {
          return size.whole(metrics) <= equal;
        })) {
      for (std::size_t index = 0; index < sizes.size(); ++index) {
        result.widths[index] = equal;
        result.fits[index] = Fit::full;
      }

      return result;
    }

    naturalWidths(result, sizes, metrics);
    if (result.footprint(metrics) <= room.width) {
      return result;
    }

    float natural = 0;
    float shortest = 0;

    for (std::size_t index = 0; index < sizes.size(); ++index) {
      if (index == focus) {
        continue;
      }

      natural += std::min(sizes[index].whole(metrics), metrics.inactive_maximum);
      shortest += std::min(sizes[index].truncated(metrics), metrics.inactive_maximum);
    }

    const auto whole = sizes[focus].whole(metrics);
    const auto share = sizes.size() == 1 ? room.width : room.width * selected_share;
    auto width = std::max(sizes[focus].compact(metrics), std::min({whole, metrics.selected_maximum, share}));
    const auto minimum = std::min(sizes[focus].truncated(metrics), metrics.selected_maximum);
    const auto caption_room = room.width - gaps - shortest;
    if (caption_room >= minimum) {
      // Preserve every caption before giving extra room to the focused tab.
      width = std::clamp(width, minimum, caption_room);
    }

    result.widths[focus] = std::min(width, room.width);
    result.fits[focus] = width >= whole ? Fit::full : Fit::truncated;
    const auto budget = room.width - width - gaps;
    if (natural <= budget) {
      return result;
    }

    const auto captioned = captionedTabs(sizes, focus, metrics, budget, shortest <= budget);

    distribute(result, sizes, captioned, metrics, budget);
    if (shortest > budget) {
      while (result.footprint(metrics) > room.width && result.end - result.first > 1) {
        if (result.end - 1 - focus >= focus - result.first) {
          --result.end;
        } else {
          ++result.first;
        }
      }
    }

    return result;
  }

  void TabStripGeometry::naturalWidths(Plan& plan, std::span<const Measure> sizes, const Metrics& metrics) noexcept {
    for (std::size_t index = 0; index < sizes.size(); ++index) {
      const auto maximum = index == plan.focus ? metrics.selected_maximum : metrics.inactive_maximum;

      plan.widths[index] = std::min(sizes[index].whole(metrics), maximum);
      plan.fits[index] = sizes[index].whole(metrics) <= maximum ? Fit::full : Fit::truncated;
    }
  }

  auto TabStripGeometry::captionedTabs(std::span<const Measure> sizes, std::size_t focus, const Metrics& metrics, float budget, bool all_fit) noexcept -> Captioned {
    Captioned captioned{};

    if (all_fit) {
      captioned.fill(true);
      captioned[focus] = false;

      return captioned;
    }

    float used = 0;

    for (std::size_t index = 0; index < sizes.size(); ++index) {
      if (index != focus) {
        used += sizes[index].compact(metrics);
      }
    }

    for (std::size_t distance = 1; distance < sizes.size(); ++distance) {
      const std::array<std::optional<std::size_t>, 2> candidates{focus >= distance ? std::optional{focus - distance} : std::nullopt, focus + distance < sizes.size() ? std::optional{focus + distance} : std::nullopt};

      for (const auto candidate : candidates) {
        if (!candidate) {
          continue;
        }

        const auto index = *candidate;
        const auto extra = std::min(sizes[index].truncated(metrics), metrics.inactive_maximum) - sizes[index].compact(metrics);
        if (used + extra <= budget) {
          captioned[index] = true;
          used += extra;
        }
      }
    }

    return captioned;
  }

  float TabStripGeometry::largestCap(std::span<const Measure> sizes, const Captioned& captioned, const Metrics& metrics, float budget) noexcept {
    float low = 0;
    auto high = metrics.inactive_maximum;

    for (std::size_t iteration = 0; iteration < cap_iterations; ++iteration) {
      const auto cap = (low + high) / 2;
      float used = 0;

      for (std::size_t index = 0; index < sizes.size(); ++index) {
        if (captioned[index]) {
          used += std::max(std::min(sizes[index].truncated(metrics), metrics.inactive_maximum), std::min({sizes[index].whole(metrics), metrics.inactive_maximum, cap}));
        }
      }

      if (used <= budget) {
        low = cap;
      } else {
        high = cap;
      }
    }

    return low;
  }

  void TabStripGeometry::distribute(Plan& plan, std::span<const Measure> sizes, const Captioned& captioned, const Metrics& metrics, float budget) noexcept {
    float fixed = 0;

    for (std::size_t index = 0; index < sizes.size(); ++index) {
      if (index != plan.focus && !captioned[index]) {
        plan.widths[index] = sizes[index].compact(metrics);
        plan.fits[index] = Fit::compact;
        fixed += sizes[index].compact(metrics);
      }
    }

    const auto cap = largestCap(sizes, captioned, metrics, budget - fixed);

    for (std::size_t index = 0; index < sizes.size(); ++index) {
      if (captioned[index]) {
        const auto minimum = std::min(sizes[index].truncated(metrics), metrics.inactive_maximum);
        const auto width = std::floor(std::max(minimum, std::min({sizes[index].whole(metrics), metrics.inactive_maximum, cap})));

        plan.widths[index] = width;
        plan.fits[index] = width >= sizes[index].whole(metrics) ? Fit::full : Fit::truncated;
      }
    }
  }

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
