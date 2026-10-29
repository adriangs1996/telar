#pragma once

#include <cstdint>
#include <span>

namespace telar::gui::platform {

struct SecureRandom {
  static void fill(std::span<std::uint8_t> output);
};

}
