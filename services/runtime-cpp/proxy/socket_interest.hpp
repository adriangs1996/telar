#pragma once

#include "../platform/byte_stream.hpp"

namespace telar::runtime {

struct SocketInterest {
  bool readable = false;
  bool writable = false;

  void include(StreamReadiness readiness) noexcept {
    readable = readable || readiness == StreamReadiness::readable;
    writable = writable || readiness == StreamReadiness::writable;
  }

  bool operator==(const SocketInterest &) const noexcept = default;

  bool satisfies(StreamReadiness readiness) const noexcept {
    return (readiness == StreamReadiness::readable && readable) || (readiness == StreamReadiness::writable && writable);
  }
};

struct TunnelReadiness {
  SocketInterest child;
  SocketInterest origin;

  static constexpr TunnelReadiness available() noexcept {
    return {{true, true}, {true, true}};
  }
};

}
