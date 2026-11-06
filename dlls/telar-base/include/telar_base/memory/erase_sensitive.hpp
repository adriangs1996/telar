#pragma once

#include <cstddef>
#include <cstring>

namespace telar {

inline void eraseSensitive(void *storage, std::size_t length) noexcept {
  if (length == 0) {
    return;
  }

  std::memset(storage, 0, length);
  // The memory clobber preserves the wipe after the buffer's final use without forcing byte stores.
  asm volatile("" : : "r"(storage) : "memory");
}

}
