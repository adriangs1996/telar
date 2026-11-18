// How panes, tabs and the cards of a tab's panes move between frames, and how a pane's call
// for attention fades. Each window holds its own motions and reads them every frame.
export module telar.gui.features.workbench:motions;

import std;

import :tabs;
import telar.gui.foundation.core;
import telar.gui.foundation.model;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: presentation/attention_fades.cppm
export {
  namespace telar::gui::features::workbench {

    struct PaneAttentionKey {
      std::uint64_t pane_id = 0;
      std::uint64_t attachment_generation = 0;

      bool operator==(const PaneAttentionKey&) const = default;
    };

    struct AttentionFrame {
      float alpha = 1;
      ds::Option<std::uint64_t> deadline_ns = ds::none;
    };

    class AttentionFades {
    public:
      static constexpr std::uint64_t duration_ns = 360'000'000;
      static constexpr std::size_t capacity = 2 * PaneLayout::maximum_panes;

      void begin() noexcept;

      [[nodiscard]] AttentionFrame sample(PaneAttentionKey key, std::uint64_t now_ns, std::uint64_t interval_ns) noexcept;

      void end() noexcept;

      [[nodiscard]] std::size_t size() const noexcept;

    private:
      struct Entry {
        PaneAttentionKey key;
        std::uint64_t started_ns = 0;
      };

      [[nodiscard]] static std::uint64_t after(std::uint64_t now_ns, std::uint64_t interval_ns) noexcept;

      [[nodiscard]] ds::Option<std::size_t> find(PaneAttentionKey key) const noexcept;

      ds::Array<Entry, capacity> entries_{};
      ds::Array<bool, capacity> seen_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: presentation/tab_motion_frame.cppm
export {
  namespace telar::gui::features::workbench {
    struct TabMotionFrame {
      static constexpr std::uint64_t default_interval_ns = 16'666'667;
      std::uint64_t now_ns = 0;
      std::uint64_t interval_ns = default_interval_ns;
      ds::Option<std::uint64_t> deadline_ns;

      void begin(std::uint64_t timestamp) noexcept;

      void request(std::uint64_t started, std::uint64_t duration) noexcept;

    private:
      static std::uint64_t add(std::uint64_t left, std::uint64_t right) noexcept;
    };
  }
}

// Interface: presentation/pane_motions.cppm
export {
  namespace telar::gui::features::workbench {

    struct TabCardPose {
      float x = 0;
      float y = 0;
      float rotation = 0;
      float scale = 1;

      bool operator==(const TabCardPose&) const = default;
    };

    struct TabCardInput {
      std::uint64_t pane = 0;
      bool focused = false;
      bool attention = false;
    };

    struct TabCardPlacement {
      std::uint64_t pane = 0;
      std::size_t rank = 0;
      TabCardPose pose;
      bool lifted = false;
    };

    struct TabCardMotion {
      static constexpr std::uint64_t duration_ns = 220'000'000;
      static constexpr std::uint64_t lift_ns = 99'000'000;
      static constexpr std::uint64_t settle_ns = duration_ns - lift_ns;
      // The focused card clears the stack before it lands in front.
      static constexpr TabCardPose lift{.x = 9.1F, .y = -5.5F, .rotation = -8, .scale = 1.06F};
      static constexpr ds::Array<TabCardPose, 3> rest{{
          {.x = 0, .y = 0, .rotation = -5, .scale = 1},
          {.x = 7, .y = 0, .rotation = -3, .scale = 0.93F},
          {.x = 14.3F, .y = 0, .rotation = -1, .scale = 0.83F},
      }};

      std::uint64_t pane = 0;
      std::uint64_t used = 0;
      std::uint64_t started = 0;
      TabCardPose from;
      TabCardPose to;
      std::size_t rank = 0;
      bool hop = false;
      bool seen = true;

      [[nodiscard]] static TabCardPose mix(TabCardPose start, TabCardPose end, float progress) noexcept;

      [[nodiscard]] std::uint64_t duration() const noexcept;

      [[nodiscard]] bool lifted(std::uint64_t now_ns) const noexcept;

      [[nodiscard]] TabCardPose value(std::uint64_t now_ns) const noexcept;
    };

    // Remembers focus order per pane without allocating, so stacks stay stable between frames.
    class TabCardMotions {
    public:
      static constexpr std::size_t capacity = 256;
      static constexpr std::size_t maximum_cards = 4;

      void begin() noexcept;

      std::size_t place(std::span<const TabCardInput> panes, std::span<TabCardPlacement> placed, TabMotionFrame& frame) noexcept;

      void finish() noexcept;

    private:
      [[nodiscard]] TabCardMotion* find(std::uint64_t pane) noexcept;

      ds::Array<TabCardMotion, capacity> entries_{};
      std::size_t count_ = 0;
      std::uint64_t clock_ = 0;
    };

    struct PaneMotionSlot {
      std::uint64_t id = 0;
      Rect bounds;
    };

    // Layout targets are committed once. Only presentation rectangles move.
    class PaneMotions {
    public:
      static constexpr std::uint64_t opening_ns = 180'000'000;
      static constexpr std::uint64_t closing_ns = 150'000'000;

      void update(std::span<const PaneMotionSlot> placements, std::uint64_t now_ns, bool immediate = false) noexcept;

      [[nodiscard]] Rect place(std::size_t index, TabMotionFrame& frame) const noexcept;

    private:
      struct Motion {
        std::uint64_t id = 0;
        Rect from;
        Rect to;
        std::uint64_t started = 0;
        std::uint64_t duration = 0;

        [[nodiscard]] Rect value(std::uint64_t now_ns) const noexcept;
      };

      [[nodiscard]] const Motion* find(std::uint64_t id) const noexcept;

      [[nodiscard]] Rect entrance(Rect target) const noexcept;

      ds::Array<Motion, PaneLayout::maximum_panes> entries_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: presentation/tab_motions.cppm
export {
  namespace telar::gui::features::workbench {

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

      [[nodiscard]] Rect value(std::uint64_t now_ns) const noexcept;

      [[nodiscard]] Rect place(Rect bounds, TabMotionFrame& frame, bool immediate = false) noexcept;
    };

    class TabMotions {
    public:
      static constexpr std::uint64_t duration_ns = TabMotion::duration_ns;

      void begin(ds::Option<WorkspaceLocation> workspace) noexcept;

      [[nodiscard, gnu::always_inline]] Rect place(TabMotionSlot slot, TabMotionFrame& frame) noexcept;

      void finish() noexcept;

      [[nodiscard]] std::size_t size() const noexcept;

    private:
      ds::Array<TabMotion, TabStripGeometry::maximum_tabs> entries_{};
      std::size_t count_ = 0;
      ds::Option<WorkspaceLocation> workspace_;
    };

  }
}
