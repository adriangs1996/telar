#pragma once
#include <algorithm>
#include <cstdint>
#include <limits>
#include <optional>

namespace telar::gui {
struct TabMotionFrame {
  static constexpr std::uint64_t default_interval_ns = 16'666'667;
  std::uint64_t now_ns = 0;
  std::uint64_t interval_ns = default_interval_ns;
  std::optional<std::uint64_t> deadline_ns;

  void begin(std::uint64_t timestamp) noexcept {
    now_ns = std::max(now_ns, timestamp);
    deadline_ns.reset();
  }

  void request(std::uint64_t started, std::uint64_t duration) noexcept {
    std::uint64_t next = 0;
    if (now_ns < started) {
      next = started;
    } else if (duration != 0 && now_ns - started < duration) {
      next = std::min(add(now_ns, interval_ns), add(started, duration));
    } else {
      return;
    }
    if (!deadline_ns || next < *deadline_ns) {
      deadline_ns = next;
    }
  }

private:
  static std::uint64_t add(std::uint64_t left, std::uint64_t right) noexcept {
    return left + std::min(std::numeric_limits<std::uint64_t>::max() - left, right);
  }
};
}
