#pragma once

#include "half.hpp"

namespace telar::runtime {

template <Allocator Memory>
struct CapturedExchange {
  using Half = Owned<CaptureHalf<Memory>, Memory>;

  explicit CapturedExchange(Memory &memory) noexcept
      : request(nullptr, AllocationDeleter<CaptureHalf<Memory>, Memory>{memory}),
        response(nullptr, AllocationDeleter<CaptureHalf<Memory>, Memory>{memory}) {}

  void include(Half half) noexcept {
    (half->side == CaptureSide::request ? request : response) = std::move(half);
  }

  Half request;
  Half response;
};

}
