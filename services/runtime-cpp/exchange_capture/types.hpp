#pragma once

#include <cstdint>
#include <string_view>

namespace telar::runtime {

enum class CaptureSide {
  request,
  response
};

enum class CapturePart {
  request_head,
  request_body,
  response_head,
  response_body
};

enum class CaptureOutcome {
  finished,
  failed,
  reset
};

enum class CaptureProtocol {
  http1,
  http2,
  upgraded
};

struct CaptureKey {
  std::uint64_t connection = 0;
  std::uint32_t stream = 0;

  bool operator==(const CaptureKey &) const = default;
};

struct CaptureTruncation {
  bool part = false;
  bool exchange = false;
  bool total = false;
};

struct CaptureStart {
  CaptureKey key{};
  CaptureSide side = CaptureSide::request;
  CaptureProtocol protocol = CaptureProtocol::http1;
  std::string_view host{};
  std::int64_t started_at_ms = 0;
};

}
