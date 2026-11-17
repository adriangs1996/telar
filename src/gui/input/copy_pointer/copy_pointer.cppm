export module telar.gui.input.copy_pointer;

import std;

import telar.gui.foundation.terminal;

// Interface: input/click_tracker.cppm
export {
  namespace telar::gui {

    class ClickTracker {
    public:
      static constexpr auto interval = std::chrono::milliseconds{500};
      static constexpr auto interval_ns = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(interval).count());

      CopyGranularity press(CopyPoint position, std::uint64_t now_ns) noexcept;

    private:
      static constexpr unsigned maximum_clicks = 3;

      CopyPoint last_{};
      std::uint64_t last_ns_ = 0;
      unsigned count_ = 0;
    };

  }
}

// Interface: input/copy_pointer.cppm
export {
  namespace telar::gui {

    enum class CopyPointerKind : std::uint8_t {
      press,
      drag,
      release,
      wheel,
      move,
    };

    struct CopyPress {
      std::uint64_t pane_id = 0;
      CopyPoint position{};
      std::uint64_t now_ns = 0;
    };

    struct CopyPointerInput {
      std::uint64_t pane_id = 0;
      CopyPoint position{};
      CopyPointerKind kind = CopyPointerKind::press;
      bool left_button = true;
      bool inside = true;
      std::int32_t rows = 0;
    };

    struct CopyPointerOwner {
      std::uint64_t pane_id = 0;
      bool dragging = false;
    };

    struct CopyPointerAuthority {
      enum class Kind : std::uint8_t {
        unowned,
        missing,
        selection,
        keyboard,
      };

      Kind kind = Kind::unowned;
      bool dragging = false;
      bool inside = false;
      std::optional<CopyPoint> position = std::nullopt;
    };

    struct CopyPointerDecision {
      enum class Outcome : std::uint8_t {
        unowned,
        consumed,
        moved,
        exited,
      };

      Outcome outcome = Outcome::unowned;
      bool cancel = false;
      bool leave = false;
      std::optional<CopyPoint> motion = std::nullopt;
      std::optional<std::int32_t> vertical = std::nullopt;
    };

    CopyPointerDecision routeCopyPointer(const CopyPointerInput& input, const CopyPointerAuthority& authority) noexcept;

  }
}
