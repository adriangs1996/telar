#pragma once

#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>

namespace telar::gui {

struct StatusAgeInterval {
  static constexpr std::uint64_t nanoseconds_per_second = 1'000'000'000;
  std::uint64_t age_ns = 0;
  std::uint64_t sampled_ns = 0;

  [[nodiscard]] std::uint64_t elapsed(std::uint64_t now_ns) const noexcept {
    const auto delta = now_ns > sampled_ns ? now_ns - sampled_ns : 0;

    return age_ns + std::min(std::numeric_limits<std::uint64_t>::max() - age_ns, delta);
  }

  [[nodiscard]] std::uint32_t seconds(std::uint64_t now_ns) const noexcept {
    return static_cast<std::uint32_t>(std::min<std::uint64_t>(std::numeric_limits<std::uint32_t>::max(), elapsed(now_ns) / nanoseconds_per_second));
  }

  bool operator==(const StatusAgeInterval &) const = default;
};

struct StatusAgeSample {
  std::uint64_t pane_id = 0;
  std::uint64_t pane_generation = 0;
  AgentStatus status = AgentStatus::unknown;
  AgentProvider provider = AgentProvider::unknown;
  std::uint32_t reported_seconds = 0;

  [[nodiscard]] bool continues(const StatusAgeSample &previous) const noexcept {
    return pane_id == previous.pane_id && pane_generation == previous.pane_generation && status == previous.status && provider == previous.provider && reported_seconds >= previous.reported_seconds;
  }
};

class StatusAge {
public:
  void observe(StatusAgeSample sample, std::uint64_t now_ns) noexcept {
    auto age_ns = static_cast<std::uint64_t>(sample.reported_seconds) * StatusAgeInterval::nanoseconds_per_second;
    if (sample.continues(sample_)) {
      age_ns = std::max(age_ns, interval_.elapsed(now_ns));
    }

    sample_ = sample;
    interval_ = {.age_ns = age_ns, .sampled_ns = now_ns};
  }

  [[nodiscard]] bool observed() const noexcept {
    return sample_.pane_id != 0;
  }

  [[nodiscard]] StatusAgeInterval interval() const noexcept {
    return interval_;
  }

private:
  StatusAgeSample sample_;
  StatusAgeInterval interval_;
};

}
