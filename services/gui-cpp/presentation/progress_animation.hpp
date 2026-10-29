#pragma once

#include "core/cosine.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#include <numbers>

namespace telar::gui {

struct ProgressAnimation {
  static constexpr std::uint64_t period_ns = 1'400'000'000;
  static constexpr float minimum_fraction = 0.22F;
  static constexpr float fraction_range = 0.18F;

  struct Frame {
    float fraction = 0;
    float turns = 0;
  };

  template <Cosine Function = StandardCosine>
  [[nodiscard]] static Frame indeterminate(std::uint64_t now_ns) noexcept {
    const auto phase = static_cast<float>(now_ns % period_ns) / static_cast<float>(period_ns);
    const auto angle = phase * 2 * std::numbers::pi_v<float>;
    const auto cosine = Function::evaluate(angle);

    return {.fraction = minimum_fraction + (fraction_range * (1 - cosine)), .turns = phase};
  }

  [[nodiscard]] static std::uint64_t nextStep(std::uint64_t now_ns, std::uint64_t interval_ns) noexcept {
    const auto remaining = interval_ns - (now_ns % interval_ns);

    return now_ns + std::min(std::numeric_limits<std::uint64_t>::max() - now_ns, remaining);
  }
};

}
