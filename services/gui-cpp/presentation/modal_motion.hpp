#pragma once

#include <algorithm>
#include <cstdint>
#include <limits>
#include <optional>

namespace telar::gui {

class ModalMotion {
public:
  static constexpr std::uint64_t duration_ns = 220'000'000;

  [[nodiscard]] float sample(std::optional<std::uint64_t> generation, std::optional<std::uint64_t> timestamp) noexcept {
    if (!generation) {
      *this = {};

      return 1;
    }

    if (!timestamp) {
      *this = {};
      generation_ = generation;

      return 1;
    }

    if (generation_ != generation) {
      generation_ = generation;
      started_ns_ = timestamp;
    }

    if (!started_ns_) {
      return 1;
    }

    if (*timestamp < *started_ns_) {
      return 0;
    }

    if (*timestamp - *started_ns_ >= duration_ns) {
      return 1;
    }

    const auto progress = static_cast<float>(*timestamp - *started_ns_) / static_cast<float>(duration_ns);
    const float remaining = 1 - progress;
    const float square = remaining * remaining;
    const float cube = square * remaining;

    return 1 - cube;
  }

  [[nodiscard]] std::optional<std::uint64_t> deadline(std::uint64_t now_ns, std::uint64_t interval_ns) const noexcept {
    if (!started_ns_ || (now_ns >= *started_ns_ && now_ns - *started_ns_ >= duration_ns)) {
      return {};
    }

    if (now_ns < *started_ns_) {
      return started_ns_;
    }

    return std::min(add(now_ns, interval_ns), add(*started_ns_, duration_ns));
  }

private:
  [[nodiscard]] static std::uint64_t add(std::uint64_t left, std::uint64_t right) noexcept {
    return left + std::min(std::numeric_limits<std::uint64_t>::max() - left, right);
  }

  std::optional<std::uint64_t> generation_;
  std::optional<std::uint64_t> started_ns_;
};

}
