#pragma once

#include "../http1/observer.hpp"
#include "counters.hpp"
#include "http1_capture_policy.hpp"

namespace telar::runtime {

template <Http1CapturePolicy Capture>
class Http1TransportObserver {
public:
  explicit Http1TransportObserver(ProxyCounters &counters, Capture &capture, CaptureSide side) noexcept : counters_(counters), capture_(capture), side_(side) {}

  void headStarted() noexcept {}
  void head(std::string_view bytes) noexcept { capture_.head(side_, bytes); }
  void payload(std::span<const std::uint8_t> bytes) noexcept { capture_.payload(side_, bytes); }

  void lineTooLong(Http1Line line) noexcept {
    counters_.record(line == Http1Line::chunk_size ? ProxyCounter::http1_chunk_line_too_long : ProxyCounter::http1_trailer_line_too_long);
  }

private:
  ProxyCounters &counters_;
  Capture &capture_;
  CaptureSide side_;
};

static_assert(Http1Observer<Http1TransportObserver<IgnoreHttp1Capture>>);

}
