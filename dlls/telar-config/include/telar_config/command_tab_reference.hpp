#pragma once

#include <cstdint>

namespace telar::runtime::config {

struct CommandTabReference {
  std::uint32_t epoch = 0;
  std::uint16_t id = 0;

  bool operator==(const CommandTabReference &) const = default;
};

}
