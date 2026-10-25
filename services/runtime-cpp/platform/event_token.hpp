#pragma once

#include <cstdint>

namespace telar::runtime {

inline constexpr std::uint64_t maximum_event_identity = UINT64_MAX >> 3;

enum class EventSource : std::uint64_t {
  listener = 0,
  client = 1,
  pane = 2,
  worker = 3,
  execution_output = 4,
  execution_error = 5,
  execution_input = 6,
  handshake = 7
};

inline constexpr std::uint64_t eventToken(EventSource source, std::uint64_t identity) noexcept {
  constexpr unsigned source_bits = 3;
  return (identity << source_bits) | static_cast<std::uint64_t>(source);
}

inline constexpr std::uint64_t eventIdentity(std::uint64_t token) noexcept {
  constexpr unsigned source_bits = 3;
  return token >> source_bits;
}

inline constexpr EventSource eventSource(std::uint64_t token) noexcept {
  constexpr std::uint64_t source_mask = 7;
  return static_cast<EventSource>(token & source_mask);
}

}
