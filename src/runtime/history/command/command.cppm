export module telar.runtime.history.command;

import std;
import telar.wire.vocabulary;

import telar.platform.events;
import telar.base.ds;

export namespace telar::runtime {

  // A shell command as history records it, when it starts and when it ends: command_capture
  // produces it and history stores it.
  struct CapturedCommand {
    std::string_view command;
    std::string_view directory;
    // The machine a remote shell ran it on, empty for this one, and the git branch it ran on.
    std::string_view host;
    std::string_view branch;
    ObservationTime started{};
    std::int64_t duration_ns = 0;
    ds::Option<int> exit_code = ds::none;
    HistoryStatus status = HistoryStatus::completed;
    HistoryAuthor author = HistoryAuthor::human;
    bool truncated = false;
    std::span<const Byte> output;
    std::uint64_t output_observed = 0;

    [[nodiscard]] constexpr bool outputTruncated() const noexcept {
      return output_observed > output.size();
    }
  };

}
