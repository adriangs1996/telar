#pragma once

#include <bitset>
#include <cstdint>

namespace telar::runtime {

struct ProxyPortRange {
  static constexpr std::uint16_t first = 45100;
  static constexpr std::uint16_t count = 128;
  using Set = std::bitset<count>;

  static constexpr bool contains(std::uint16_t port) noexcept {
    return port >= first && port < first + count;
  }
};

}
