#pragma once

#include "../http2/event.hpp"

namespace telar::runtime {

template <typename Capture>
concept Http2CapturePolicy = requires(Capture &capture, Http2Direction direction, const Http2Event &event) {
  { capture.observe(direction, event) } noexcept -> std::same_as<void>;
  { capture.finish(direction) } noexcept -> std::same_as<void>;
};

struct IgnoreHttp2Capture {
  void observe(Http2Direction, const Http2Event &) noexcept {}
  void finish(Http2Direction) noexcept {}
};

static_assert(Http2CapturePolicy<IgnoreHttp2Capture>);

}
