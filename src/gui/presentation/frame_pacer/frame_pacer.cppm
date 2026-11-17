export module telar.gui.presentation.frame_pacer;

import std;

import telar.gui.layout.geometry;

import telar.gui.foundation.core;
import telar.gui.links.link_hover;
import telar.wire.vocabulary;

// Interface: presentation/attention_fades.cppm
export {
  namespace telar::gui {

    struct PaneAttentionKey {
      std::uint64_t pane_id = 0;
      std::uint64_t attachment_generation = 0;

      bool operator==(const PaneAttentionKey&) const = default;
    };

    struct AttentionFrame {
      float alpha = 1;
      std::optional<std::uint64_t> deadline_ns = std::nullopt;
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

      [[nodiscard]] std::optional<std::size_t> find(PaneAttentionKey key) const noexcept;

      std::array<Entry, capacity> entries_{};
      std::array<bool, capacity> seen_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: presentation/frame_pacer.cppm
export {
  namespace telar::gui {

    class FramePacer {
    public:
      struct Pane {
        std::uint64_t pane_id = 0;
        std::uint64_t frame_id = 0;
        bool attached = false;
        std::uint64_t attachment_generation = 0;
        std::uint64_t graphics_revision = 0;
      };

      static constexpr std::uint64_t nanoseconds_per_second = 1'000'000'000;
      static constexpr std::uint64_t default_interval_ns = nanoseconds_per_second / Configuration::default_fps;
      static constexpr std::uint64_t minimum_interval_ns = nanoseconds_per_second / Configuration::maximum_fps;
      static constexpr std::uint64_t maximum_interval_ns = nanoseconds_per_second / Configuration::minimum_fps;
      static constexpr std::uint64_t input_grace_ns = 30'000'000;
      static constexpr std::uint32_t input_frame_budget = 16;
      static constexpr std::size_t capacity = PaneLayout::maximum_panes;

      [[nodiscard]] static std::uint64_t resolveInterval(std::uint64_t display_interval_ns, std::optional<std::uint16_t> maximum_fps) noexcept;

      std::uint64_t configure(std::uint64_t display_interval_ns, std::optional<std::uint16_t> maximum_fps) noexcept;

      [[nodiscard]] std::uint64_t interval() const noexcept;

      void noteInput(Pane pane, std::uint64_t now_ns) noexcept;

      [[nodiscard]] bool canAdvanceInput(Pane pane, std::uint64_t now_ns) const noexcept;

      [[nodiscard]] std::optional<std::uint64_t> waitUntil(std::span<const Pane> panes, std::uint64_t now_ns) const noexcept;

      void record(std::span<const Pane> panes, std::uint64_t now_ns) noexcept;

    private:
      struct InputGrace {
        Pane pane;
        std::uint64_t started_ns;
        std::uint32_t frames_left = input_frame_budget;

        [[nodiscard]] bool includes(Pane candidate) const noexcept;

        [[nodiscard]] bool rejects(Pane candidate, std::uint64_t now_ns) const noexcept;

        [[nodiscard]] bool active(std::uint64_t now_ns) const noexcept;
      };

      [[nodiscard]] static std::uint64_t after(std::uint64_t now_ns, std::uint64_t interval_ns) noexcept;

      [[nodiscard]] bool ordinaryAvailable(std::uint64_t now_ns) const noexcept;

      std::array<std::optional<InputGrace>, capacity> inputs_{};
      std::uint64_t interval_ns_ = default_interval_ns;
      std::optional<std::uint64_t> anchor_ns_;
      std::optional<std::uint64_t> last_preparation_ns_;
    };

  }
}

// Interface: presentation/tab_motion_frame.cppm
export {
  namespace telar::gui {
    struct TabMotionFrame {
      static constexpr std::uint64_t default_interval_ns = 16'666'667;
      std::uint64_t now_ns = 0;
      std::uint64_t interval_ns = default_interval_ns;
      std::optional<std::uint64_t> deadline_ns;

      void begin(std::uint64_t timestamp) noexcept;

      void request(std::uint64_t started, std::uint64_t duration) noexcept;

    private:
      static std::uint64_t add(std::uint64_t left, std::uint64_t right) noexcept;
    };
  }
}

// Interface: presentation/pane_motions.cppm
export {
  namespace telar::gui {

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
      static constexpr std::array<TabCardPose, 3> rest{{
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

      std::array<TabCardMotion, capacity> entries_{};
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

      std::array<Motion, PaneLayout::maximum_panes> entries_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: presentation/tab_strip_geometry.cppm
export {
  namespace telar::gui {

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
      static constexpr std::array<float, 3> chip_widths{28, 35, 42};
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
        std::array<float, maximum_tabs> widths{};
        std::array<Fit, maximum_tabs> fits{};
        std::size_t first = 0;
        std::size_t end = 0;
        std::size_t focus = 0;
        std::size_t count = 0;

        [[nodiscard]] std::size_t hidden() const noexcept;

        [[nodiscard]] bool shows(std::size_t index) const noexcept;

        [[nodiscard]] std::optional<std::size_t> nearestHidden() const noexcept;

        [[nodiscard]] float footprint(const Metrics& metrics) const noexcept;
      };

      [[nodiscard]] static Plan arrange(std::span<const Measure> sizes, std::size_t focus, const Room& room) noexcept;

    private:
      using Captioned = std::array<bool, maximum_tabs>;

      static void naturalWidths(Plan& plan, std::span<const Measure> sizes, const Metrics& metrics) noexcept;

      [[nodiscard]] static Captioned captionedTabs(std::span<const Measure> sizes, std::size_t focus, const Metrics& metrics, float budget, bool all_fit) noexcept;

      [[nodiscard]] static float largestCap(std::span<const Measure> sizes, const Captioned& captioned, const Metrics& metrics, float budget) noexcept;

      static void distribute(Plan& plan, std::span<const Measure> sizes, const Captioned& captioned, const Metrics& metrics, float budget) noexcept;
    };

  }
}

// Interface: presentation/tab_motions.cppm
export {
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

      [[nodiscard]] Rect value(std::uint64_t now_ns) const noexcept;

      [[nodiscard]] Rect place(Rect bounds, TabMotionFrame& frame, bool immediate = false) noexcept;
    };

    class TabMotions {
    public:
      static constexpr std::uint64_t duration_ns = TabMotion::duration_ns;

      void begin(std::optional<WorkspaceLocation> workspace) noexcept;

      [[nodiscard, gnu::always_inline]] Rect place(TabMotionSlot slot, TabMotionFrame& frame) noexcept;

      void finish() noexcept;

      [[nodiscard]] std::size_t size() const noexcept;

    private:
      std::array<TabMotion, TabStripGeometry::maximum_tabs> entries_{};
      std::size_t count_ = 0;
      std::optional<WorkspaceLocation> workspace_;
    };

  }
}

// Interface: presentation/terminal_preparation.cppm
export {
  namespace telar::gui {

    struct TerminalPreparation {
      FramePacer::Pane pane;
      std::optional<PresentedLink> links;
      std::uint64_t revision = 0;
    };

  }
}
