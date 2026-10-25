#pragma once

#include <algorithm>
#include <cstdint>

namespace telar::runtime {

inline void advanceIdentityCounter(std::uint64_t &counter, std::uint64_t next) noexcept {
  // Zero marks exhaustion after the last nonzero identity; restoring an older counter must not reopen it.
  if (counter != 0) {
    counter = next == 0 ? 0 : std::max(counter, next);
  }
}

}
