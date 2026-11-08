module;
#include "tbc/view.hpp"
#include "telar_platform/trace_macro.hpp"
#include <new>
#include <ghostty/vt.h>
#include <stdlib.h>
#include <zlib.h>

#include <cstdint>

#include <cstring>
#include <cstddef>
#include "telar_base/diagnostics/config.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include "cell_layout.hpp"
#include <cassert>

#include <cerrno>
#include <pthread.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

export module telar.runtime.observation.processor;

import std;

export import telar.config;


export import telar.runtime.agents.screen_inference;
export import telar.runtime.command_capture.tracker;
export import telar.runtime.diagnostics.runtime_counters;
export import telar.runtime.history.event;


export import telar.runtime.platform.request_worker;
export import telar.runtime.platform.process_probe;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;

// Interface: observation/batch.cppm
export {
namespace telar::runtime {

enum class ObservationKind {
  input,
  output,
  resize,
  shell_exit,
  session_end
};

struct ObservationEvent {
  ObservationKind kind = ObservationKind::output;
  ObservationTime time;
  std::uint32_t offset = 0;
  std::uint32_t length = 0;
  std::optional<bool> shell_foreground = std::nullopt;
  TerminalSize size{};
  int exit_code = 0;
};

struct ObservationBatch {
  inline void clear() noexcept {
    byte_count = 0;
    event_count = 0;
    reset_before = false;
  }

  inline std::span<const Byte> bytesOf(const ObservationEvent &event) const noexcept {
    return std::span{bytes}.subspan(event.offset, event.length);
  }

  static constexpr std::size_t byte_capacity = 128 * 1024;
  static constexpr std::size_t event_capacity = 512;
  std::array<Byte, byte_capacity> bytes;
  std::array<ObservationEvent, event_capacity> events;
  std::size_t byte_count = 0;
  std::size_t event_count = 0;
  bool reset_before = false;
};

}
}

// Interface: observation/pane_observer.cppm
export {
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
  inline explicit PaneObserver(Memory &memory, TerminalSize size, std::string_view directory = {}, bool capture_output = false)
      : terminal_(memory, size, TerminalPurpose::observation),
        tracker_(memory, terminal_, directory, capture_output),
        workspace_path_(AllocatorRef<char, Memory>{memory}),
        shell_(AllocatorRef<char, Memory>{memory}),
        initial_size_(size) {}

  inline void configureHistory(const HistorySession &session, bool capture_output = false) {
    session_ = session;
    workspace_path_.assign(session.workspace_path);
    shell_.assign(session.shell);
    session_.workspace_path = workspace_path_;
    session_.shell = shell_;
    if (capture_output) {
      tracker_.enableOutputCapture();
    }
  }

  inline void updateDirectory(std::string_view directory) {
    tracker_.updateDirectory(directory);
  }

  inline std::string_view observedDirectory() const noexcept {
    return tracker_.directory();
  }

  inline void noteInjectedSubmission() noexcept {
    injected_submissions_.fetch_add(1, std::memory_order_relaxed);
  }

  inline void bytes(ObservationKind kind, std::span<const Byte> bytes, std::optional<bool> shell_foreground) noexcept {
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

  inline void resize(TerminalSize size) noexcept {
    control(ObservationEvent{.kind = ObservationKind::resize, .time = ObservationTime::now(), .size = size});
  }

  inline void shellExit(int code) noexcept {
    control(ObservationEvent{.kind = ObservationKind::shell_exit, .time = ObservationTime::now(), .exit_code = code});
  }

  inline void finishSession() noexcept {
    control(ObservationEvent{.kind = ObservationKind::session_end, .time = ObservationTime::now()});
  }

  inline bool idle() const noexcept {
    return !sealed_ && batches_[active_].event_count == 0;
  }

  inline bool seal(bool allow_empty = false) noexcept {
    if (sealed_ || (!allow_empty && batches_[active_].event_count == 0)) {
      return false;
    }

    sealed_ = active_;
    active_ ^= 1;
    return true;
  }

  inline void complete() noexcept {
    batches_[*sealed_].clear();
    sealed_.reset();
  }

  inline std::optional<LimitReach> takeDrop() noexcept {
    return std::exchange(drop_, std::nullopt);
  }

  template <HistoryEventSink History>
  inline ScreenObservationResult observe(const AgentManifests &manifests, AgentProvider provider, History &history, bool inspect_screen = true) noexcept {
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

  inline ScreenObservationResult observe(const AgentManifests &manifests, AgentProvider provider, bool inspect_screen = true) noexcept {
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

    inline void emit(const CapturedCommand &command) {
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

  inline void control(const ObservationEvent &event) noexcept {
    auto &batch = batches_[active_];
    if (batch.event_count == ObservationBatch::event_capacity) {
      drop(0);
    }

    batch.events[batch.event_count++] = event;
  }

  inline void drop(std::size_t incoming) noexcept {
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
}

// Interface: observation/processor.cppm
export {
namespace telar::runtime {

template <typename Probe>
concept PaneProcessProbe = ObservationService<Probe> && requires(Probe &probe, pid_t process) {
  { probe.directory(process) } noexcept -> std::same_as<FixedText<4096>>;
};

template <Allocator Memory, PaneProcessProbe Probe, HistoryEventSink History>
class ObservationProcessor {
public:
  struct RequestEntry {
    std::uint64_t pane = 0;
    std::uint64_t generation = 0;
    AgentProvider provider = AgentProvider::unknown;
    std::shared_ptr<PaneObserver<Memory>> observer;
    ProcessProbeRequest process_request{};
    bool probe_process = false;
    bool tracked_agent = false;
    std::uint64_t input_revision = 0;
  };

  struct Request {
    std::array<RequestEntry, 8> entries;
    std::size_t count = 0;
  };

  struct ResultEntry {
    std::uint64_t pane = 0;
    std::uint64_t generation = 0;
    std::uint64_t cwd_revision = 0;
    std::uint64_t input_revision = 0;
    std::shared_ptr<PaneObserver<Memory>> observer;
    ScreenObservationResult screen{};
    std::optional<ProcessProbeResult> process_result;
    bool process_recheck = false;
  };

  struct Result {
    std::array<ResultEntry, 8> entries;
    std::size_t count = 0;
  };

  inline explicit ObservationProcessor(const AgentManifests &manifests, Probe &probe, History &history) noexcept
      : manifests_(manifests),
        probe_(probe),
        history_(history) {}

  // The result carries the request's observers on.
  inline tbc::view<Result, tbc::lt::a> observe(tbc::view<const Request &, tbc::lt::a> request) noexcept {
    Result result;
    typename Probe::Request process_request;
    for (const auto &entry : std::span{request.entries}.first(request.count)) {
      if (entry.probe_process) {
        process_request.panes[process_request.count++] = entry.process_request;
      }
    }

    std::optional<typename Probe::Result> processes;
    if (process_request.count != 0) {
      processes = probe_.observe(process_request);
    }

    for (const auto &entry : std::span{request.entries}.first(request.count)) {
      auto &observed = result.entries[result.count++];
      observed.pane = entry.pane;
      observed.generation = entry.generation;
      observed.cwd_revision = entry.process_request.cwd_revision;
      observed.input_revision = entry.input_revision;
      observed.process_recheck = entry.process_request.recheck;
      observed.observer = entry.observer;
      auto provider = entry.provider;
      if (processes) {
        for (const auto &process : std::span{processes->panes}.first(processes->count)) {
          if (process.request.pane != entry.pane) {
            continue;
          }

          observed.process_result = process;
          provider = process.provider;
          if (const auto *manifest = manifests_.find(provider)) {
            observed.process_result->name.assign(manifest->displayName());
          }
          break;
        }
      }

      observed.screen = entry.observer->observe(manifests_, provider, history_, entry.tracked_agent || provider != AgentProvider::unknown);

      // Process snapshots follow the sealed input batch in time; applying their CWD first can rewrite a cd command's source directory.
      if (observed.process_result && !observed.process_result->cwd.view().empty()) {
        entry.observer->updateDirectory(observed.process_result->cwd.view());
      } else if (!observed.process_result && entry.process_request.root > 0) {
        const auto directory = probe_.directory(entry.process_request.root);
        if (!directory.view().empty()) {
          entry.observer->updateDirectory(directory.view());
        }
      }
    }

    return result;
  }

  inline void stop() noexcept {}

private:
  const AgentManifests &manifests_;
  Probe &probe_;
  History &history_;
};

}
}
