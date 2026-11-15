export module telar.gui.input.child_mouse;

import std;

import telar.gui.core.metrics;
import telar.gui.input.wheel_accumulator;
import telar.wire.vocabulary;

// Interface: input/child_mouse.cppm
export {
  namespace telar::gui {

    enum class MouseButton : std::uint8_t {
      left,
      middle,
      right,
      none,
    };

    enum class MousePhase : std::uint8_t {
      press,
      drag,
      release,
      move,
    };

    struct ChildMouseSample {
      MouseButton button = MouseButton::left;
      MousePhase phase = MousePhase::press;
      Point position;
      unsigned modifiers = 0;
    };

    struct ChildMouseView {
      std::uint64_t pane_id = 0;
      TabLocation location;
      TerminalSurface surface{};
      Mouse protocol{};
      std::uint16_t columns = 0;
      std::uint16_t rows = 0;
      std::uint16_t cell_width_px = 0;
      std::uint16_t cell_height_px = 0;
      bool attached = false;
      bool visible = true;
    };

    struct ChildMouseReport {
      unsigned button = 0;
      unsigned x = 0;
      unsigned y = 0;
      bool released = false;

      bool operator==(const ChildMouseReport&) const = default;
    };

    class ChildMouseProjection {
    public:
      static constexpr unsigned motion = 32;

      [[nodiscard]] static bool tracked(const Mouse& protocol, MousePhase phase) noexcept;

      [[nodiscard]] static std::optional<ChildMouseReport> project(const ChildMouseView& view, const ChildMouseSample& sample) noexcept;

      [[nodiscard]] static bool valid(const TerminalSurface& surface) noexcept;

    private:
      [[nodiscard]] static unsigned coordinate(double position, unsigned extent) noexcept;
    };

    class ChildMouseGesture {
    public:
      void begin(const ChildMouseView& view, ChildMouseSample sample) noexcept;

      [[nodiscard]] bool owned() const noexcept;

      [[nodiscard]] std::optional<ChildMouseReport> deliver(const ChildMouseView& view, ChildMouseSample sample) noexcept;

      [[nodiscard]] std::optional<ChildMouseReport> cancel(const ChildMouseView& view) noexcept;

    private:
      bool owned_ = false;
      std::optional<ChildMouseView> capture_;
      ChildMouseSample last_;
    };

  }
}

// Interface: input/history_scroll.cppm
export {
  namespace telar::gui {

    struct HistoryScrollState {
      std::uint64_t generation = 0;
      std::uint64_t revision = 0;
      bool ready = false;
      bool inspecting = false;
    };

    struct HistoryScrollSurface {
      Rect bounds{};
      std::uint64_t generation = 0;
      std::uint64_t revision = 0;
      double row_height = 1;
      double cell_height = 1;
      double scale = 1;
      bool delivered = false;
      bool has_rows = false;
    };

    struct HistoryScrollPosition {
      double x = 0;
      double y = 0;
    };

    class HistoryScroll {
    public:
      [[nodiscard]] std::int32_t consume(HistoryScrollState state, const HistoryScrollSurface& surface, HistoryScrollPosition pointer, ScrollSample sample) noexcept;

    private:
      [[nodiscard]] static bool within(Rect bounds, HistoryScrollPosition pointer) noexcept;

      WheelAccumulator wheel_;
      std::uint64_t generation_ = 0;
      bool inspecting_ = false;
    };

  }
}
