#pragma once

#include "../platform/byte_stream.hpp"

namespace telar::runtime {

struct SocketInterest {
  bool readable = false;
  bool writable = false;
  bool completion = false;

  void include(StreamReadiness readiness) noexcept {
    readable = readable || readiness == StreamReadiness::readable;
    writable = writable || readiness == StreamReadiness::writable;
    completion = completion || readiness == StreamReadiness::completion;
  }

  auto operator==(const SocketInterest &) const noexcept -> bool = default;

  [[nodiscard]] auto satisfies(StreamReadiness readiness) const noexcept -> bool {
    return (readiness == StreamReadiness::readable && readable) || (readiness == StreamReadiness::writable && writable) || (readiness == StreamReadiness::completion && completion);
  }
};

struct TunnelReadiness {
  SocketInterest child;
  SocketInterest origin;

  static constexpr auto available() noexcept -> TunnelReadiness {
    return {
        .child = {
            .readable = true,
            .writable = true,
            .completion = true,
        },
        .origin = {
            .readable = true,
            .writable = true,
            .completion = true,
        },
    };
  }
};

}
