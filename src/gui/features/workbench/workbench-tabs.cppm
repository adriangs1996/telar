// The tab strip: how wide each tab is and which ones show, and a tab the user drags to another
// place in it.
export module telar.gui.features.workbench:tabs;

import std;

import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: presentation/tab_strip_geometry.cppm
export {
  namespace telar::gui::features::workbench {

    struct TabStripGeometry {
      static constexpr std::size_t maximum_tabs = 64;
      static constexpr std::size_t cap_iterations = 24;
      static constexpr float pill_height = 30;
      static constexpr float pill_radius = pill_height / 2;
      static constexpr float leading = 14;
      static constexpr float trailing = 14;
      static constexpr float spacing = 12;
      static constexpr float tile_width = 26;
      static constexpr float tile_height = 20;
      static constexpr float tile_radius = 6;
      static constexpr float mark_side = 14;
      static constexpr float path_gap = 6;
      static constexpr float gap = 0;
      // One card, then each card behind it adds a visible sliver.
      static constexpr ds::Array<float, 3> chip_widths{28, 35, 42};
      static constexpr float inactive_maximum = 320;
      static constexpr float selected_maximum = 420;
      static constexpr float selected_share = 0.55F;
      static constexpr float caption_minimum = 56;
      static constexpr float counter_width = 36;
      static constexpr float fade_width = 20;

      enum class Fit : std::uint8_t {
        full,
        truncated,
        compact,
      };

      struct Metrics {
        float leading;
        float trailing;
        float spacing;
        float gap;
        float inactive_maximum;
        float selected_maximum;
        float caption_minimum;
        float counter;

        [[nodiscard]] static Metrics scaled(float ratio) noexcept;
      };

      struct Measure {
        float caption = 0;
        float chip = 0;
        float status = 0;

        [[nodiscard]] float statusSpace(const Metrics& metrics) const noexcept;

        [[nodiscard]] float whole(const Metrics& metrics) const noexcept;

        [[nodiscard]] float truncated(const Metrics& metrics) const noexcept;

        [[nodiscard]] float compact(const Metrics& metrics) const noexcept;
      };

      struct Room {
        float width;
        Metrics metrics;
      };

      struct Plan {
        ds::Array<float, maximum_tabs> widths{};
        ds::Array<Fit, maximum_tabs> fits{};
        std::size_t first = 0;
        std::size_t end = 0;
        std::size_t focus = 0;
        std::size_t count = 0;

        [[nodiscard]] std::size_t hidden() const noexcept;

        [[nodiscard]] bool shows(std::size_t index) const noexcept;

        [[nodiscard]] ds::Option<std::size_t> nearestHidden() const noexcept;

        [[nodiscard]] float footprint(const Metrics& metrics) const noexcept;
      };

      [[nodiscard]] static Plan arrange(std::span<const Measure> sizes, std::size_t focus, const Room& room) noexcept;

    private:
      using Captioned = ds::Array<bool, maximum_tabs>;

      static void naturalWidths(Plan& plan, std::span<const Measure> sizes, const Metrics& metrics) noexcept;

      [[nodiscard]] static Captioned captionedTabs(std::span<const Measure> sizes, std::size_t focus, const Metrics& metrics, float budget, bool all_fit) noexcept;

      [[nodiscard]] static float largestCap(std::span<const Measure> sizes, const Captioned& captioned, const Metrics& metrics, float budget) noexcept;

      static void distribute(Plan& plan, std::span<const Measure> sizes, const Captioned& captioned, const Metrics& metrics, float budget) noexcept;
    };

  }
}

// Interface: input/tab_drag.cppm
export {
  namespace telar::gui::features::workbench {

    struct TabDropTarget {
      ds::Option<std::uint64_t> relative_to;
      TabMoveDirection direction = TabMoveDirection::previous;
    };

    struct TabDragMove {
      TabLocation location;
      TabMoveDirection direction = TabMoveDirection::previous;
      ds::Option<std::uint64_t> relative_to;
    };

    class TabDrag {
    public:
      using Position = ds::Array<double, 2>;
      static constexpr double logical_threshold = 4;

      void begin(TabLocation source, Position point) noexcept;
      void cancel() noexcept;
      void validate(ds::Option<WorkspaceLocation> workspace, std::span<const std::uint64_t> tabs, bool naming) noexcept;
      void update(Position point, ds::Option<TabDropTarget> destination) noexcept;
      [[nodiscard]] ds::Option<TabDragMove> preview() const noexcept;
      [[nodiscard]] ds::Option<TabDragMove> finish() noexcept;
      [[nodiscard]] bool captured() const noexcept;
      [[nodiscard]] bool dragging() const noexcept;
      [[nodiscard]] const ds::Option<TabLocation>& source() const noexcept;
      [[nodiscard]] const ds::Option<TabDropTarget>& destination() const noexcept;

    private:
      bool captured_ = false;
      ds::Option<TabLocation> source_;
      Position origin_{};
      bool dragging_ = false;
      ds::Option<TabDropTarget> destination_;
    };

  }
}

// Interface: input/tab_drop_slots.cppm
export {
  namespace telar::gui::features::workbench {

    struct TabDropSlot {
      std::uint64_t id = 0;
      Rect bounds;
    };

    class TabDropSlots {
    public:
      static constexpr std::size_t capacity = TabStripGeometry::maximum_tabs;

      void capture(std::span<const TabDropSlot> delivered) noexcept;
      [[nodiscard]] ds::Option<TabDropTarget> at(TabDrag::Position point) const noexcept;
      [[nodiscard]] std::span<const TabDropSlot> view() const noexcept;

    private:
      ds::Array<TabDropSlot, capacity> entries_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: input/tab_drop_surface.cppm
export {
  namespace telar::gui::features::workbench {

    struct TabDropSurface {
      ds::Array<TabDropSlot, TabDropSlots::capacity> targets{};
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
