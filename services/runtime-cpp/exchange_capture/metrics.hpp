#pragma once

#include <cstdint>

namespace telar::runtime {

struct CaptureMetrics {
  std::uint64_t started = 0;
  std::uint64_t truncated = 0;
  std::uint64_t truncated_part = 0;
  std::uint64_t truncated_exchange = 0;
  std::uint64_t truncated_total = 0;
  std::uint64_t skipped = 0;
  std::uint64_t decode_failed = 0;
  std::uint64_t dropped_queue = 0;
  std::uint64_t queued = 0;
  std::uint64_t queue_high_water = 0;
};

}
