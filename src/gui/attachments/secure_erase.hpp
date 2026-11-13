#pragma once

#include <cstddef>
#include <span>

namespace telar::gui {

inline void eraseSensitiveBytes(std::span<std::byte> bytes) noexcept {
  volatile std::byte *const sensitive = bytes.data();
  for (std::size_t index = 0; index < bytes.size(); ++index) {
    sensitive[index] = std::byte{};
  }
}

}
