#pragma once

#include <cstddef>
#include <cstdlib>
#include <stdlib.h>

#if defined(__linux__)
#include <cerrno>
#include <sys/random.h>
#endif

namespace telar::runtime {

// Fills `size` bytes at `data` from the kernel's random source, never
// failing: arc4random_buf on macOS, getrandom on Linux, where musl has no
// arc4random. A Linux that cannot answer getrandom aborts rather than hand
// out predictable nonces.
inline void randomBytes(void *data, std::size_t size) noexcept {
#if defined(__linux__)
  auto *cursor = static_cast<unsigned char *>(data);
  while (size != 0) {
    const auto count = ::getrandom(cursor, size, 0);
    if (count < 0) {
      if (errno == EINTR) {
        continue;
      }

      std::abort();
    }

    cursor += count;
    size -= static_cast<std::size_t>(count);
  }
#else
  ::arc4random_buf(data, size);
#endif
}

}
