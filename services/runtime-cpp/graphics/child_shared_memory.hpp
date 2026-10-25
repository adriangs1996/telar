#pragma once

#include "../platform/file_descriptor.hpp"
#include "child_name.hpp"
#include <array>
#include <fcntl.h>
#include <limits.h>
#include <sys/mman.h>

namespace telar::runtime {

class GraphicsChildSharedMemory {
public:
  static FileDescriptor open(std::string_view encoded_name, std::span<std::uint8_t> name) noexcept {
    const auto *decoded = decodeGraphicsName(encoded_name, name);
    return FileDescriptor{decoded == nullptr ? -1 : ::shm_open(decoded, O_RDONLY, 0)};
  }

  static void release(std::string_view encoded_name) noexcept {
    std::array<std::uint8_t, PATH_MAX + 1> name;
    const auto descriptor = open(encoded_name, name);
    if (descriptor) {
      ::shm_unlink(reinterpret_cast<const char *>(name.data()));
    }
  }
};

}
