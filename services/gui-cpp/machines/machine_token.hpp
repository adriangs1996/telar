#pragma once

#include <cstdint>

namespace telar::gui {

struct MachineToken {
  std::uint8_t slot = 0;
  std::uint64_t generation = 0;

  bool operator==(const MachineToken &) const noexcept = default;
};

}
