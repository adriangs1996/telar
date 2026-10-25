#pragma once

#include <array>
#include <span>
#include <sys/types.h>

namespace telar::runtime {

struct ProcessLineage {
  std::span<const pid_t> ancestors() const noexcept {
    return std::span{processes}.first(count);
  }

  std::array<pid_t, 64> processes{};
  unsigned count = 0;
  bool descends = false;
};

}
