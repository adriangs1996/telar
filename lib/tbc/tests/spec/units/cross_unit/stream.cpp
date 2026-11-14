#include "stream.hpp"

#include <unistd.h>

namespace cross_unit {
  int socket_stream::read(std::span<unsigned char> destination) noexcept {
    return static_cast<int>(::read(descriptor_, destination.data(), destination.size()));
  }

  int socket_stream::write(std::span<const unsigned char> bytes) noexcept {
    return static_cast<int>(::write(descriptor_, bytes.data(), bytes.size()));
  }
}
