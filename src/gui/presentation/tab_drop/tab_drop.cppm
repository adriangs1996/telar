export module telar.gui.presentation.tab_drop;

import std;

export import telar.gui.core.metrics;
export import telar.gui.presentation.frame_pacer;
import telar.wire.vocabulary;

// Interface: input/tab_drag.cppm
export {
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

      inline void begin(TabLocation source, Position point) noexcept {
        *this = {};
        captured_ = true;
        source_ = source;
        origin_ = point;
      }

      inline void cancel() noexcept {
        source_.reset();
        destination_.reset();
        dragging_ = false;
      }

      inline void validate(std::optional<WorkspaceLocation> workspace, std::span<const std::uint64_t> tabs, bool naming) noexcept {
        if (source_ && (naming || !workspace || workspace->kind != source_->workspace.kind || workspace->id != source_->workspace.id || std::ranges::find(tabs, source_->tab_id) == tabs.end())) {
          cancel();
        }
      }

      inline void update(Position point, std::optional<TabDropTarget> destination) noexcept {
        if (!source_) {
          return;
        }

        constexpr double threshold = 1;

        dragging_ = dragging_ || std::abs(point[0] - origin_[0]) >= threshold || std::abs(point[1] - origin_[1]) >= threshold;
        destination_ = dragging_ && destination && destination->relative_to != source_->tab_id ? destination : std::nullopt;
      }

      [[nodiscard]] inline std::optional<TabDragMove> preview() const noexcept {
        if (!source_ || !destination_) {
          return std::nullopt;
        }

        return TabDragMove{.location = *source_, .direction = destination_->direction, .relative_to = destination_->relative_to};
      }

      [[nodiscard]] inline std::optional<TabDragMove> finish() noexcept {
        const auto result = preview();

        *this = {};

        return result;
      }

      [[nodiscard]] inline bool captured() const noexcept {
        return captured_;
      }

      [[nodiscard]] inline bool dragging() const noexcept {
        return dragging_;
      }

      [[nodiscard]] inline const std::optional<TabLocation>& source() const noexcept {
        return source_;
      }

      [[nodiscard]] inline const std::optional<TabDropTarget>& destination() const noexcept {
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
}

// Interface: input/tab_drop_slots.cppm
export {
  namespace telar::gui {

    struct TabDropSlot {
      std::uint64_t id = 0;
      Rect bounds;
    };

    class TabDropSlots {
    public:
      static constexpr std::size_t capacity = TabStripGeometry::maximum_tabs;

      inline void capture(std::span<const TabDropSlot> delivered) noexcept {
        count_ = std::min(delivered.size(), entries_.size());
        std::copy_n(delivered.begin(), count_, entries_.begin());
      }

      [[nodiscard]] inline std::optional<TabDropTarget> at(TabDrag::Position point) const noexcept {
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

      [[nodiscard]] inline std::span<const TabDropSlot> view() const noexcept {
        return std::span{entries_}.first(count_);
      }

    private:
      std::array<TabDropSlot, capacity> entries_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: input/tab_drop_surface.cppm
export {
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

      [[nodiscard]] inline const TabDropSlot* at(TabDrag::Position point) const noexcept {
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

      [[nodiscard]] inline std::span<const TabDropSlot> view() const noexcept {
        return std::span{targets}.first(count);
      }
    };

  }
}
