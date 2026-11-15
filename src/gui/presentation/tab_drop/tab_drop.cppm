export module telar.gui.presentation.tab_drop;

import std;

import telar.gui.core.metrics;
import telar.gui.presentation.frame_pacer;
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

      void begin(TabLocation source, Position point) noexcept;
      void cancel() noexcept;
      void validate(std::optional<WorkspaceLocation> workspace, std::span<const std::uint64_t> tabs, bool naming) noexcept;
      void update(Position point, std::optional<TabDropTarget> destination) noexcept;
      [[nodiscard]] std::optional<TabDragMove> preview() const noexcept;
      [[nodiscard]] std::optional<TabDragMove> finish() noexcept;
      [[nodiscard]] bool captured() const noexcept;
      [[nodiscard]] bool dragging() const noexcept;
      [[nodiscard]] const std::optional<TabLocation>& source() const noexcept;
      [[nodiscard]] const std::optional<TabDropTarget>& destination() const noexcept;

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

      void capture(std::span<const TabDropSlot> delivered) noexcept;
      [[nodiscard]] std::optional<TabDropTarget> at(TabDrag::Position point) const noexcept;
      [[nodiscard]] std::span<const TabDropSlot> view() const noexcept;

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

      [[nodiscard]] const TabDropSlot* at(TabDrag::Position point) const noexcept;
      [[nodiscard]] std::span<const TabDropSlot> view() const noexcept;
    };

  }
}
