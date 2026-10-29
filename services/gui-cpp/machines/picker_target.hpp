#pragma once

#include "machine_token.hpp"
#include <optional>

namespace telar::gui {

struct MachinePickerTarget {
  std::optional<MachineToken> machine;
};

}
