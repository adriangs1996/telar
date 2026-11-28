module telar.gui.foundation.core;

import std;

namespace telar::gui::inline foundation::inline core {

  std::int32_t WheelAccumulator::consume(ScrollSample sample) noexcept {
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

  void WheelAccumulator::reset() noexcept {
    remainder_ = 0;
  }

}
