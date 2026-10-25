#pragma once

#include <cstddef>
#include <cstdint>

namespace telar::runtime::diagnostics {

struct RequestQueueSnapshot {
  std::size_t depth = 0;
  std::size_t high_water = 0;
  std::uint64_t dropped = 0;
};

}
