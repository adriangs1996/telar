// When the window prepares its next frame: at the display's cadence, and sooner for the pane
// the user types into. Each window holds its own pacer and asks it every frame.
export module telar.gui.features.window:pacer;

import std;

import telar.gui.foundation.core;
import telar.gui.foundation.model;

// Interface: presentation/frame_pacer.cppm
export {
  namespace telar::gui::features::window {

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
