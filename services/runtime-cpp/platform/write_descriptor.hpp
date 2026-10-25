#pragma once

#include <cerrno>
#include <cstdint>
#include <span>
#include <unistd.h>

namespace telar::runtime {

inline int writeDescriptor(int descriptor, std::span<const std::uint8_t> bytes) noexcept {
  while (!bytes.empty()) {
    const auto count = ::write(descriptor, bytes.data(), bytes.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      return count == 0 ? EIO : errno;
    }

    bytes = bytes.subspan(static_cast<std::size_t>(count));
  }
  return 0;
}

}
