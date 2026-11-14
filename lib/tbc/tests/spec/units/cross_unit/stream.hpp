#ifndef TBC_SPEC_CROSS_UNIT_STREAM_HPP
#define TBC_SPEC_CROSS_UNIT_STREAM_HPP

#include <span>

// Socket streams known by their declarations, as the proxy knows `SocketStream`, whose bodies
// `lib/platform/net/net.cpp` defines.
namespace cross_unit {
  // `stream.cpp` defines its reads and writes, which change no storage a caller can borrow.
  class socket_stream {
  public:
    int read(std::span<unsigned char> destination) noexcept;
    int write(std::span<const unsigned char> bytes) noexcept;

  private:
    int descriptor_ = -1;
  };

  // No checked unit defines its reads and writes.
  class opaque_stream {
  public:
    int read(std::span<unsigned char> destination) noexcept;
    int write(std::span<const unsigned char> bytes) noexcept;

  private:
    int descriptor_ = -1;
  };
}

#endif
