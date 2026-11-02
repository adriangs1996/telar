#pragma once

#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include <cstdint>
#include <optional>

namespace telar::gui {

struct HistoryLoading {
  static constexpr std::uint64_t steps = 40;
  static constexpr std::uint64_t step_ns = 24'000'000;
  static constexpr float row_opacity = 0.55F;
  static constexpr float thickness = 2;
  static constexpr float span_divisor = 3;

  [[nodiscard]] static Rect line(Rect area, ChromeMetrics chrome, std::optional<std::uint64_t> now_ns) noexcept {
    const auto step = now_ns ? (*now_ns / step_ns) % steps : steps / 3;
    const auto span = area.width / span_divisor;
    const auto travel = area.width + span;
    const auto x = area.x - span + (travel * static_cast<float>(step) / static_cast<float>(steps));

    return {.x = x, .y = area.y, .width = span, .height = chrome.px(thickness)};
  }
};

}
