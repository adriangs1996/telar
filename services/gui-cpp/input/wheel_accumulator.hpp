#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace telar::gui {

enum class ScrollPhase : std::uint8_t {
  none,
  begin,
  update,
  end,
  cancel,
};

struct ScrollSample {
  double delta = 0;
  double cell_height = 1;
  bool precise = false;
  ScrollPhase phase = ScrollPhase::none;
};

class WheelAccumulator {
public:
  static constexpr std::int32_t maximum_lines = 32;
  static constexpr std::int32_t rows_per_line = 3;

  [[nodiscard]] std::int32_t consume(ScrollSample sample) noexcept {
    if (sample.phase == ScrollPhase::begin || sample.phase == ScrollPhase::cancel) {
      reset();
    }

    if (sample.phase == ScrollPhase::cancel || !std::isfinite(sample.delta) || !std::isfinite(sample.cell_height)) {
      return 0;
    }

    const auto unit = sample.precise ? std::max(1.0, sample.cell_height) : 1.0;
    constexpr auto limit = static_cast<double>(maximum_lines);
    remainder_ += std::clamp(sample.delta / unit, -limit, limit);
    const auto lines = std::clamp(std::trunc(remainder_), -limit, limit);
    remainder_ -= lines;

    return static_cast<std::int32_t>(lines);
  }

  void reset() noexcept {
    remainder_ = 0;
  }

private:
  double remainder_ = 0;
};

}
