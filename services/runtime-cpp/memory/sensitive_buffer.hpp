#pragma once

#include "erase_sensitive.hpp"
#include <array>
#include <cstdint>
#include <span>

namespace telar::runtime {

template <std::size_t Capacity>
class SensitiveBuffer {
public:
  SensitiveBuffer() noexcept {}

  ~SensitiveBuffer() {
    eraseSensitive(bytes_.data(), bytes_.size());
  }

  SensitiveBuffer(const SensitiveBuffer &) = delete;
  SensitiveBuffer &operator=(const SensitiveBuffer &) = delete;

  std::span<std::uint8_t, Capacity> bytes() noexcept {
    return bytes_;
  }

private:
  std::array<std::uint8_t, Capacity> bytes_;
};

}
