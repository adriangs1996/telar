module;

#include <cstdint>
#include <span>
#include <cerrno>
#include <exception>
#include <algorithm>
#include <cstddef>
#if (defined(__APPLE__))
#include <sys/random.h>
#endif
#if (!(defined(__APPLE__)))
#include <unistd.h>
#endif

module telar.gui.platform.private_file_stamp;

import telar.platform;


#ifdef __APPLE__
#include <sys/random.h>
#else
#include <unistd.h>
#endif

namespace telar::gui::platform {

void SecureRandom::fill(std::span<std::uint8_t> output) {
  constexpr std::size_t maximum_entropy_bytes = 256;
  while (!output.empty()) {
    const auto chunk = output.first(std::min(output.size(), maximum_entropy_bytes));
    if (::getentropy(chunk.data(), chunk.size()) != 0) {
      if (errno == EINTR) {
        continue;
      }

      throw runtime::SystemError{"Read secure random bytes"};
    }

    output = output.subspan(chunk.size());
  }
}

}
