#pragma once

#include "line.hpp"

namespace telar::runtime::diagnostics {

struct SystemCounters {
  Timing sample;
  std::chrono::steady_clock::time_point captured{};

  void write(Line &line) const {
    line.timing("system_sample_avg_us", "system_sample_max_us", sample);
    const auto age = std::chrono::steady_clock::now() - captured;
    const auto age_ms = static_cast<std::uint64_t>(std::max<std::int64_t>(0, std::chrono::duration_cast<std::chrono::milliseconds>(age).count()));
    line.field("system_sample_age_ms", sample.count == 0 ? std::nullopt : std::optional<std::uint64_t>{age_ms});
  }
};

}
