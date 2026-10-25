#pragma once

#include "command.hpp"
#include "input_scanner.hpp"
#include "osc_zones.hpp"
#include "output_tail.hpp"
#include "terminal_selection.hpp"

namespace telar::runtime {

template <Allocator Memory>
class CommandTracker {
public:
  explicit CommandTracker(Memory &memory, Terminal<Memory> &terminal, std::string_view directory, bool capture_output = false)
      : terminal_(terminal),
        selection_(terminal),
        zones_(directory),
        output_(memory, capture_output),
        command_(AllocatorRef<Byte, Memory>{memory}) {}

  void enableOutputCapture() {
    output_.enable();
  }

  template <CapturedCommandSink Sink>
  std::size_t input(const CommandByteObservation &observation, Sink &sink) {
    TELAR_TRACE("history.captureInput");
    const bool shell_foreground = observation.shell_foreground.value_or(zones_.editing());
    zones_.input(observation.bytes);
    if (!shell_foreground || observation.bytes.empty() || !selection_.primary()) {
      return 0;
    }

    if (phase_ == Phase::running) {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.next_input_completions));
      auto finished = observation.time;
      if (last_output_ns_ >= started_.nanoseconds) {
        finished.nanoseconds = last_output_ns_;
      }

      complete({finished, std::nullopt, HistoryStatus::completed}, sink);
    }

    if (phase_ == Phase::awaiting_commit) {
      return observation.bytes.size();
    }

    if (phase_ == Phase::idle) {
      selection_.begin();
      input_.reset();
      phase_ = Phase::editing;
    }

    const auto event = input_.feed(observation.bytes);
    if (event.cancelled) {
      reset();
      return observation.bytes.size();
    }

    if (event.submitted && phase_ == Phase::editing) {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.submissions));
      phase_ = Phase::awaiting_commit;
      started_ = observation.time;
      last_output_ns_ = started_.nanoseconds;
      saw_foreground_child_ = false;
      command_directory_.assign(zones_.directory());
    }

    return observation.bytes.size();
  }

  template <CapturedCommandSink Sink>
  void output(CommandByteObservation observation, Sink &sink) {
    TELAR_TRACE("history.captureOutput");
    while (!observation.bytes.empty()) {
      const auto boundary = phase_ == Phase::awaiting_commit ? std::ranges::find(observation.bytes, '\n') : observation.bytes.end();
      const bool committed = boundary != observation.bytes.end();
      const auto count = committed ? static_cast<std::size_t>(boundary - observation.bytes.begin()) + 1 : observation.bytes.size();
      const auto part = observation.bytes.first(count);
      terminal_.feed(part);
      terminal_.discardResponses();
      if (committed) {
        const auto captured = selection_.capture(command_);
        if (captured) {
          TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.captures));
          truncated_ = *captured;
          phase_ = Phase::running;
        } else {
          TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.capture_failures));
          reset();
        }
      }

      afterOutput({part, observation.time, observation.shell_foreground}, sink);
      observation.bytes = observation.bytes.subspan(count);
    }
  }

  template <CapturedCommandSink Sink>
  void complete(CommandCompletion completion, Sink &sink) {
    if (phase_ == Phase::running && !command_.empty()) {
      sink.emit(CapturedCommand{
          .command = {reinterpret_cast<const char *>(command_.data()), command_.size()},
          .directory = command_directory_.view(),
          .started = started_,
          .duration_ns = std::max<std::int64_t>(0, completion.time.nanoseconds - started_.nanoseconds),
          .exit_code = completion.exit_code,
          .status = completion.status,
          .truncated = truncated_,
          .output = output_.bytes(),
          .output_observed = output_.observed(),
      });
    }

    reset();
  }

  void reset() noexcept {
    phase_ = Phase::idle;
    command_.clear();
    input_.reset();
    output_.clear();
    truncated_ = false;
    saw_foreground_child_ = false;
  }

  void resetObservation() {
    TELAR_DIAGNOSTIC(metrics_.merge(zones_.takeMetrics()));
    reset();
    zones_ = CommandZones{zones_.directory()};
  }

  void updateDirectory(std::string_view directory) {
    zones_.setDirectory(directory);
  }

  std::string_view directory() const noexcept {
    return zones_.directory();
  }

  bool markersReady() const noexcept {
    return zones_.markersReady();
  }

  bool needsForegroundObservation() const noexcept {
    return phase_ == Phase::awaiting_commit || phase_ == Phase::running;
  }

#if TELAR_DIAGNOSTICS
  diagnostics::CommandCaptureCounters takeMetrics() noexcept {
    auto result = std::exchange(metrics_, {});
    result.merge(zones_.takeMetrics());
    return result;
  }
#endif

private:
  enum class Phase {
    idle,
    editing,
    awaiting_commit,
    running
  };

  template <CapturedCommandSink Sink>
  struct CompletionRelay {
    CommandTracker &tracker;
    Sink &sink;

    void complete(CommandCompletion completion) {
      if (tracker.phase_ == Phase::running) {
        TELAR_DIAGNOSTIC(diagnostics::accumulate(tracker.metrics_.auxiliary_completions));
        tracker.complete(completion, sink);
      }
    }
  };

  template <CapturedCommandSink Sink>
  void afterOutput(const CommandByteObservation &observation, Sink &sink) {
    last_output_ns_ = observation.time.nanoseconds;
    if ((phase_ == Phase::editing || phase_ == Phase::awaiting_commit) && !selection_.primary()) {
      reset();
    }

    if (phase_ == Phase::editing) {
      selection_.rebase(input_.typedText());
    }

    if (phase_ == Phase::running) {
      output_.append(observation.bytes);
    }

    CompletionRelay<Sink> relay{*this, sink};
    zones_.feed(observation.bytes, observation.time, relay);
    if (phase_ != Phase::running || !observation.shell_foreground) {
      return;
    }

    if (!*observation.shell_foreground) {
      saw_foreground_child_ = true;
    } else if (saw_foreground_child_) {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.foreground_completions));
      complete({observation.time, std::nullopt, HistoryStatus::completed}, sink);
    }
  }

#if TELAR_DIAGNOSTICS
  diagnostics::CommandCaptureCounters metrics_;
#endif
  Terminal<Memory> &terminal_;
  CommandSelection<Memory> selection_;
  CommandZones zones_;
  CommandOutputTail<Memory> output_;
  Vector<Byte, Memory> command_;
  CommandInputScanner input_;
  FixedText<4096> command_directory_;
  ObservationTime started_;
  std::int64_t last_output_ns_ = 0;
  Phase phase_ = Phase::idle;
  bool truncated_ = false;
  bool saw_foreground_child_ = false;
};

}
