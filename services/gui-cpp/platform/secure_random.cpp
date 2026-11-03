#include "secure_random.hpp"
#include "telar_platform/error.hpp"
#include <algorithm>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <span>

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
