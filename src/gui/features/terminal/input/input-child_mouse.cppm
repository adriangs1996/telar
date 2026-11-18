// The pointer over a terminal whose program tracks the mouse: the presses, drags and releases a
// pane's gesture reports to it, in the cells its program reads.
export module telar.gui.features.terminal.input:child_mouse;

import std;

import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: input/child_mouse.cppm
export {
  namespace telar::gui::features::terminal::input {

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

      [[nodiscard]] static ds::Option<ChildMouseReport> project(const ChildMouseView& view, const ChildMouseSample& sample) noexcept;

      [[nodiscard]] static bool valid(const TerminalSurface& surface) noexcept;

    private:
      [[nodiscard]] static unsigned coordinate(double position, unsigned extent) noexcept;
    };

    class ChildMouseGesture {
    public:
      void begin(const ChildMouseView& view, ChildMouseSample sample) noexcept;

      [[nodiscard]] bool owned() const noexcept;

      [[nodiscard]] ds::Option<ChildMouseReport> deliver(const ChildMouseView& view, ChildMouseSample sample) noexcept;

      [[nodiscard]] ds::Option<ChildMouseReport> cancel(const ChildMouseView& view) noexcept;

    private:
      bool owned_ = false;
      ds::Option<ChildMouseView> capture_;
      ChildMouseSample last_;
    };

  }
}
