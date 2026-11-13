export module telar.runtime.history.command;

import std;
import telar.wire.vocabulary;

export import telar.platform;

export namespace telar::runtime {

  // A finished shell command as history records it: command_capture produces it and
  // history stores it.
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

    constexpr bool outputTruncated() const noexcept {
      return output_observed > output.size();
    }
  };

}
