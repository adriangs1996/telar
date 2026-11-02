#pragma once

#include "terminal/copy_grid.hpp"
#include <algorithm>
#include <chrono>
#include <cstdint>

namespace telar::gui {

class ClickTracker {
public:
  static constexpr auto interval = std::chrono::milliseconds{500};
  static constexpr auto interval_ns = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(interval).count());

  CopyGranularity press(CopyPoint position, std::uint64_t now_ns) noexcept {
    const auto distance = std::max(position.x, last_.x) - std::min(position.x, last_.x);
    const auto nearby = position.y == last_.y && distance <= 1;
    const auto elapsed = now_ns - std::min(now_ns, last_ns_);
    const auto repeated = count_ != 0 && elapsed <= interval_ns;
    count_ = nearby && repeated ? std::min(count_ + 1, maximum_clicks) : 1;
    last_ = position;
    last_ns_ = now_ns;

    return static_cast<CopyGranularity>(count_ - 1);
  }

private:
  static constexpr unsigned maximum_clicks = 3;

  CopyPoint last_{};
  std::uint64_t last_ns_ = 0;
  unsigned count_ = 0;
};

}
