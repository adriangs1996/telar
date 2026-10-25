#pragma once

#include "../agents/screen_inference.hpp"
#include "../command_capture/tracker.hpp"
#include "../diagnostics/observation_counters.hpp"
#include "../history/event.hpp"
#include "batch.hpp"
#include <atomic>
#include <memory>

namespace telar::runtime {

struct ScreenObservationResult {
  std::optional<AgentSignal> signal;
  ObservationTime time;
  bool failed = false;
  bool shell_markers = false;
  bool needs_foreground = false;
#if TELAR_DIAGNOSTICS
  diagnostics::ObservationCounters metrics{};
#endif
};

template <Allocator Memory>
class PaneObserver {
public:
  explicit PaneObserver(Memory &memory, TerminalSize size, std::string_view directory = {}, bool capture_output = false)
      : terminal_(memory, size, TerminalPurpose::observation),
        tracker_(memory, terminal_, directory, capture_output),
        workspace_path_(AllocatorRef<char, Memory>{memory}),
        shell_(AllocatorRef<char, Memory>{memory}),
        initial_size_(size) {}

  void configureHistory(const HistorySession &session, bool capture_output = false) {
    session_ = session;
    workspace_path_.assign(session.workspace_path);
    shell_.assign(session.shell);
    session_.workspace_path = workspace_path_;
    session_.shell = shell_;
    if (capture_output) {
      tracker_.enableOutputCapture();
    }
  }

  void updateDirectory(std::string_view directory) {
    tracker_.updateDirectory(directory);
  }

  std::string_view observedDirectory() const noexcept {
    return tracker_.directory();
  }

  void noteInjectedSubmission() noexcept {
    injected_submissions_.fetch_add(1, std::memory_order_relaxed);
  }

  void bytes(ObservationKind kind, std::span<const Byte> bytes, std::optional<bool> shell_foreground) noexcept {
    auto &batch = batches_[active_];
    if (batch.event_count == ObservationBatch::event_capacity || bytes.size() > ObservationBatch::byte_capacity - batch.byte_count) {
      drop(bytes.size());
    }

    if (bytes.size() > ObservationBatch::byte_capacity) {
      return;
    }

    const auto offset = batch.byte_count;
    std::copy(bytes.begin(), bytes.end(), batch.bytes.begin() + offset);
    batch.byte_count += bytes.size();
    batch.events[batch.event_count++] = {kind, ObservationTime::now(), static_cast<std::uint32_t>(offset), static_cast<std::uint32_t>(bytes.size()), shell_foreground};
  }

  void resize(TerminalSize size) noexcept {
    control(ObservationEvent{.kind = ObservationKind::resize, .time = ObservationTime::now(), .size = size});
  }

  void shellExit(int code) noexcept {
    control(ObservationEvent{.kind = ObservationKind::shell_exit, .time = ObservationTime::now(), .exit_code = code});
  }

  void finishSession() noexcept {
    control(ObservationEvent{.kind = ObservationKind::session_end, .time = ObservationTime::now()});
  }

  bool idle() const noexcept {
    return !sealed_ && batches_[active_].event_count == 0;
  }

  bool seal(bool allow_empty = false) noexcept {
    if (sealed_ || (!allow_empty && batches_[active_].event_count == 0)) {
      return false;
    }

    sealed_ = active_;
    active_ ^= 1;
    return true;
  }

  void complete() noexcept {
    batches_[*sealed_].clear();
    sealed_.reset();
  }

  std::optional<LimitReach> takeDrop() noexcept {
    return std::exchange(drop_, std::nullopt);
  }

  template <HistoryEventSink History>
  ScreenObservationResult observe(const AgentManifests &manifests, AgentProvider provider, History &history, bool inspect_screen = true) noexcept {
    TELAR_TRACE("observation.replay");
    TELAR_DIAGNOSTIC(AllocationScope allocation_scope{AllocationPath::observation});
    ScreenObservationResult result;
    const auto &batch = batches_[*sealed_];
    try {
      if (!session_started_ && session_.pane != 0) {
        session_started_ = history.recordHistory({HistoryEventKind::session_started, session_});
      }

      CommandRelay<History> commands{session_, history, injected_submissions_};
      TELAR_DIAGNOSTIC(commands.metrics = &result.metrics);
      if (batch.reset_before || reset_needed_) {
        tracker_.resetObservation();
        ghostty_terminal_reset(terminal_.handle());
        terminal_.resize(initial_size_);
        inference_.reset();
        reset_needed_ = false;
        TELAR_DIAGNOSTIC(result.metrics.resets = 1);
      }

      bool output = false;
      for (const auto &event : std::span{batch.events}.first(batch.event_count)) {
        switch (event.kind) {
        case ObservationKind::output:
          tracker_.output({batch.bytesOf(event), event.time, event.shell_foreground}, commands);
          result.time = event.time;
          output = true;
          break;
        case ObservationKind::resize:
          initial_size_ = event.size;
          terminal_.resize(event.size);
          break;
        case ObservationKind::input: {
          [[maybe_unused]] const auto candidate_bytes = tracker_.input({batch.bytesOf(event), event.time, event.shell_foreground}, commands);
          TELAR_DIAGNOSTIC(diagnostics::accumulate(result.metrics.candidate_input_bytes, candidate_bytes));
          break;
        }
        case ObservationKind::shell_exit:
          tracker_.complete({event.time, event.exit_code}, commands);
          break;
        case ObservationKind::session_end:
          tracker_.complete({event.time, std::nullopt, HistoryStatus::interrupted}, commands);
          if (session_.pane != 0) {
            history.recordHistory({.kind = HistoryEventKind::session_finished, .session = session_, .finished_at_ms = event.time.milliseconds});
          }
          break;
        }
      }

      if (output && inspect_screen) {
        result.signal = inference_.observe(terminal_, manifests, provider, result.time);
      }
      result.shell_markers = tracker_.markersReady();
      result.needs_foreground = tracker_.needsForegroundObservation();
    } catch (...) {
      inference_.reset();
      result.failed = true;
      reset_needed_ = true;
      TELAR_DIAGNOSTIC(result.metrics.failures = 1);
    }

    TELAR_DIAGNOSTIC(result.metrics.commands = tracker_.takeMetrics());
    return result;
  }

  ScreenObservationResult observe(const AgentManifests &manifests, AgentProvider provider, bool inspect_screen = true) noexcept {
    DiscardedHistory history;
    return observe(manifests, provider, history, inspect_screen);
  }

  std::shared_ptr<PaneObserver> retired_next;

private:
  template <HistoryEventSink History>
  struct CommandRelay {
    const HistorySession &session;
    History &history;
    std::atomic<std::uint64_t> &injected_submissions;
#if TELAR_DIAGNOSTICS
    diagnostics::ObservationCounters *metrics = nullptr;
#endif

    void emit(const CapturedCommand &command) {
      if (session.pane != 0) {
        auto captured = command;
        if (injected_submissions.load(std::memory_order_relaxed) != 0) {
          injected_submissions.fetch_sub(1, std::memory_order_relaxed);
          captured.author = HistoryAuthor::agent;
        }

        [[maybe_unused]] const bool accepted = history.recordHistory({HistoryEventKind::command_finished, session, captured});
        TELAR_DIAGNOSTIC(diagnostics::accumulate(accepted ? metrics->captured : metrics->dropped));
      }
    }
  };

  void control(const ObservationEvent &event) noexcept {
    auto &batch = batches_[active_];
    if (batch.event_count == ObservationBatch::event_capacity) {
      drop(0);
    }

    batch.events[batch.event_count++] = event;
  }

  void drop(std::size_t incoming) noexcept {
    auto &batch = batches_[active_];
    if (batch.event_count == ObservationBatch::event_capacity) {
      drop_ = LimitReach{.name = "history.observer_batch_events", .noun = "events", .value = ObservationBatch::event_capacity, .requested = batch.event_count + 1};
    } else {
      drop_ = LimitReach{.name = "history.observer_batch_bytes", .noun = "bytes", .value = ObservationBatch::byte_capacity, .requested = batch.byte_count + incoming};
    }

    batch.clear();
    batch.reset_before = true;
  }

  std::array<ObservationBatch, 2> batches_;
  unsigned active_ = 0;
  std::optional<unsigned> sealed_;
  std::optional<LimitReach> drop_;
  Terminal<Memory> terminal_;
  CommandTracker<Memory> tracker_;
  HistorySession session_;
  String<Memory> workspace_path_;
  String<Memory> shell_;
  TerminalSize initial_size_;
  AgentScreenInference inference_;
  bool reset_needed_ = false;
  bool session_started_ = false;
  std::atomic<std::uint64_t> injected_submissions_{0};
};

}
