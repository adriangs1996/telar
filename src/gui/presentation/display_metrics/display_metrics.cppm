module;
#include "tbc/annotations.hpp"

export module telar.gui.presentation.display_metrics;

import std;

import telar.gui.foundation.core;

import telar.wire.vocabulary;

// Interface: presentation/progress_animation.cppm
export {
  namespace telar::gui {

    struct ProgressAnimation {
      static constexpr std::uint64_t period_ns = 1'400'000'000;
      static constexpr float minimum_fraction = 0.22F;
      static constexpr float fraction_range = 0.18F;

      struct Frame {
        float fraction = 0;
        float turns = 0;
      };

      // Generic over the caller's cosine, so it stays here; a few float operations per frame.
      template <Cosine Function = StandardCosine>
      [[nodiscard]] TBC_GENERIC static Frame indeterminate(std::uint64_t now_ns) noexcept {
        const auto phase = static_cast<float>(now_ns % period_ns) / static_cast<float>(period_ns);
        const auto angle = phase * 2 * std::numbers::pi_v<float>;
        const auto cosine = Function::evaluate(angle);

        return {.fraction = minimum_fraction + (fraction_range * (1 - cosine)), .turns = phase};
      }

      [[nodiscard]] static std::uint64_t nextStep(std::uint64_t now_ns, std::uint64_t interval_ns) noexcept;
    };

  }
}

// Interface: presentation/progress_motion.cppm
export {
  namespace telar::gui {

    struct ProgressSample {
      static constexpr Byte maximum_percent = 100;
      std::uint64_t pane_id = 0;
      std::uint64_t attachment = 0;
      PaneProgressState state = PaneProgressState::remove;
      std::optional<Byte> percent = std::nullopt;

      [[nodiscard]] float reported() const noexcept;

      bool operator==(const ProgressSample&) const = default;
    };

    class ProgressMotion {
    public:
      static constexpr std::uint64_t duration_ns = 240'000'000;

      [[nodiscard]] float sample(ProgressSample report, std::uint64_t now_ns) noexcept;
      [[nodiscard]] std::optional<std::uint64_t> deadline(std::uint64_t now_ns) const noexcept;

    private:
      [[nodiscard]] float value(std::uint64_t now_ns) const noexcept;

      std::uint64_t pane_id_ = 0;
      std::uint64_t attachment_ = 0;
      std::uint64_t started_ns_ = 0;
      std::uint64_t duration_ = 0;
      float from_ = 0;
      float to_ = 0;
      bool known_ = false;
    };

  }
}
