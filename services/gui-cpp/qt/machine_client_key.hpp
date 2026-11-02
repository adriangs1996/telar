#pragma once

#include "machines/machine_token.hpp"
#include <cstdint>

namespace telar::gui::qt {

struct MachineClientKey {
  MachineToken machine;
  std::uint64_t generation = 0;

  bool operator==(const MachineClientKey &) const noexcept = default;
};

}
