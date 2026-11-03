#pragma once

#include <cstdint>

namespace telar::runtime::machines {

enum class NumberRadix : std::uint8_t {
  decimal = 10,
  hexadecimal = 16,
};

}
