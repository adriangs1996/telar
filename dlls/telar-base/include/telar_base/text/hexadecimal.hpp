#pragma once

#include "telar_base/memory/allocator.hpp"
#include <cstdint>
#include <span>

namespace telar::runtime {

template <Allocator Memory>
void appendLowerHex(String<Memory> &output, std::span<const std::uint8_t> bytes) {
  constexpr std::string_view digits = "0123456789abcdef";
  for (const auto byte : bytes) {
    output += digits[byte >> 4];
    output += digits[byte & 15];
  }
}

}
