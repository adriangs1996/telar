#pragma once

#include "../platform/observation_time.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <concepts>

namespace telar::runtime {

struct CapturedCommand {
  std::string_view command;
  std::string_view directory;
  ObservationTime started{};
  std::int64_t duration_ns = 0;
  std::optional<int> exit_code = std::nullopt;
  HistoryStatus status = HistoryStatus::completed;
  HistoryAuthor author = HistoryAuthor::human;
  bool truncated = false;
  std::span<const Byte> output{};
  std::uint64_t output_observed = 0;

  bool outputTruncated() const noexcept {
    return output_observed > output.size();
  }
};

template <typename Sink>
concept CapturedCommandSink = requires(Sink &sink, const CapturedCommand &command) {
  { sink.emit(command) } -> std::same_as<void>;
};

struct CommandByteObservation {
  std::span<const Byte> bytes;
  ObservationTime time;
  std::optional<bool> shell_foreground;
};

}
