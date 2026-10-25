#pragma once

#include <concepts>
#include <cstdint>
#include <span>
#include <string_view>

namespace telar::runtime {

enum class Http2Direction { request,
                            response };

struct Http2Event {
  enum class Kind {
    request_started,
    response_activity,
    response_ended,
    stream_reset,
    connection_lost,
    request_header,
    response_header,
    request_body,
    response_body,
    request_finished
  };

  Kind kind;
  std::uint32_t stream = 0;
  std::uint16_t status = 0;
  bool event_stream = false;
  std::string_view name{};
  std::string_view value{};
  std::span<const std::uint8_t> bytes{};
};

template <typename Sink>
concept Http2EventSink = requires(Sink &sink, const Http2Event &event) {
  { sink.emit(event) } noexcept -> std::same_as<void>;
};

}
