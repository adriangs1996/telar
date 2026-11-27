module;
#include "telar_platform/trace_macro.hpp"

#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.agents.observation.processor;

import std;
import telar.ghostty.vt;
import telar.sys.posix;
import telar.tbc;

import telar.config.runtime;

import telar.runtime.agents.screen_inference;
import telar.runtime.terminal.command_capture.tracker;
import telar.runtime.diagnostics.runtime_counters;
import telar.runtime.history.event;

import telar.runtime.workers.request_worker;
import telar.runtime.host.process_probe;
import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.terminal.control;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.platform.events;
import telar.runtime.history.command;
import telar.runtime.terminal.shell_integration.token;
import telar.runtime.terminal.text_reader;
import telar.base.ds;

// Interface: observation/batch.cppm
export {
  namespace telar::runtime {

    enum class ObservationKind : std::uint8_t {
      input,
      // The text of a command a client runs, ahead of the input that types it.
      command,
      output,
      resize,
      shell_exit,
      session_end,
      // A picture of the terminal's screen, which draws the observer's after it lost bytes.
      resync,
    };

    struct ObservationEvent {
      ObservationKind kind = ObservationKind::output;
      ObservationTime time;
      std::uint32_t offset = 0;
      std::uint32_t length = 0;
      ds::Option<bool> shell_foreground = ds::none;
      TerminalSize size{};
      int exit_code = 0;
    };

    struct ObservationBatch {
      void clear() noexcept;

      [[nodiscard]] std::span<const Byte> bytesOf(const ObservationEvent& event) const noexcept;

      static constexpr std::size_t byte_capacity = std::size_t{128} * 1024;
      static constexpr std::size_t event_capacity = 512;
      ds::Array<Byte, byte_capacity> bytes;
      ds::Array<ObservationEvent, event_capacity> events;
      std::size_t byte_count = 0;
      std::size_t event_count = 0;
      bool reset_before = false;
      // Whether the batch starts with a picture of the screen the reset lost.
      bool resynced = false;
    };

  }
}

// Interface: observation/pane_observer.cppm
export {
  namespace telar::runtime {

    struct ScreenObservationResult {
      ds::Option<AgentSignal> signal;
      ObservationTime time;
      bool failed = false;
      bool shell_markers = false;
      bool needs_foreground = false;
#if TELAR_DIAGNOSTICS
      diagnostics::ObservationCounters metrics{};
#endif
    };

    // Shared by the runtime's thread and the observation worker, which hand it over rather than lock
    // it: the runtime writes the active batch and seals it; between submitting a request and
    // collecting its result the worker alone reads the sealed batch and owns the terminal, the
    // tracker and the inference; the request queue's mutex orders each handover, and the runtime
    // completes the batch only once its result came back. Only the runtime reads what the worker
    // owns, after collecting, and copies it then.
    class [[tbc::shared]] PaneObserver {
    public:
      // What the observer keeps lives in `memory`, region `a`; the directory is copied.
      explicit PaneObserver(tbc::mut_a<ConcurrentMemory> memory, TerminalSize size, std::string_view directory = {}, bool capture_output = false, ds::Option<ShellToken> shell_token = ds::none);

      void configureHistory(const HistorySession& session, bool capture_output = false);

      void updateDirectory(std::string_view directory);

      std::string_view observedDirectory() const noexcept;

      void noteInjectedSubmission() noexcept;

      void bytes(ObservationKind kind, std::span<const Byte> bytes, ds::Option<bool> shell_foreground) noexcept;

      // Whether `incoming` more bytes overflow the batch, which drops what it holds.
      [[nodiscard]] bool overflows(std::size_t incoming) const noexcept;

      // Drops the batch before `incoming` bytes that overflow it and starts the next from a picture
      // of the terminal's screen: the caller draws it into the room this returns, then sizes it with
      // `resynced`. Without it the observer's screen starts empty and an agent that redraws only
      // what changed is read wrong until it redraws everything.
      std::span<Byte> resyncRoom(std::size_t incoming) noexcept;
      void resynced(std::size_t length) noexcept;

      void resize(TerminalSize size) noexcept;

      void shellExit(int code) noexcept;

      void finishSession() noexcept;

      bool idle() const noexcept;

      bool seal(bool allow_empty = false) noexcept;

      void complete() noexcept;

      ds::Option<LimitReach> takeDrop() noexcept;

      // Generic over the caller's history sink, so it stays here.
      template <HistoryEventSink History>
      [[tbc::generic]] inline ScreenObservationResult observe(const AgentManifests& manifests, AgentProvider provider, History& history, bool inspect_screen = true) noexcept {
        TELAR_TRACE("observation.replay");
        TELAR_DIAGNOSTIC(const AllocationScope allocation_scope{AllocationPath::observation});
        ScreenObservationResult result;
        const auto& batch = batches_[*sealed_];

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
            inference_.reset(!batch.resynced || reset_needed_);
            reset_needed_ = false;
            TELAR_DIAGNOSTIC(result.metrics.resets = 1);
          }

          const bool output = replay(batch, commands, result);

          if (output && inspect_screen) {
            result.signal = inference_.observe(terminal_, manifests, provider);
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

      ScreenObservationResult observe(const AgentManifests& manifests, AgentProvider provider, bool inspect_screen = true) noexcept;

      // The next observer of the retired list this one is on.
      [[tbc::hot_path]] inline std::shared_ptr<PaneObserver>& retiredNextMut() noexcept {
        return retired_next_;
      }

    private:
      template <HistoryEventSink History>
      struct [[tbc::generic]] CommandRelay {
        const HistorySession& session;
        History& history;
        std::atomic<std::uint64_t>& injected_submissions;
#if TELAR_DIAGNOSTICS
        diagnostics::ObservationCounters* metrics = nullptr;
#endif

        inline void emit(const CapturedCommand& command) {
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

      // Replays the sealed batch's events into the tracker and the terminal; whether any was output.
      // Generic over the caller's history sink, as observe.
      template <HistoryEventSink History>
      [[tbc::generic]] inline bool replay(const ObservationBatch& batch, CommandRelay<History>& commands, ScreenObservationResult& result) {
        bool output = false;

        for (const auto& event : std::span{batch.events}.first(batch.event_count)) {
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
          case ObservationKind::command:
            tracker_.submitCommand(batch.bytesOf(event));
            break;
          case ObservationKind::resync:
            // Drawn on the screen alone: none of it is a command's output.
            terminal_.feed(batch.bytesOf(event));
            break;
          case ObservationKind::shell_exit:
            tracker_.complete({event.time, event.exit_code}, commands);
            break;
          case ObservationKind::session_end:
            tracker_.complete({event.time, ds::none, HistoryStatus::interrupted}, commands);
            if (session_.pane != 0) {
              commands.history.recordHistory({.kind = HistoryEventKind::session_finished, .session = session_, .finished_at_ms = event.time.milliseconds});
            }

            break;
          }
        }

        return output;
      }

      void control(const ObservationEvent& event) noexcept;

      void drop(std::size_t incoming) noexcept;

      ds::Array<ObservationBatch, 2> batches_;
      unsigned active_ = 0;
      ds::Option<unsigned> sealed_;
      ds::Option<LimitReach> drop_;
      tbc::val_a<Terminal> terminal_;
      // Reads terminal_.
      tbc::val_self<CommandTracker> tracker_;
      tbc::val_self<HistorySession> session_;
      tbc::val_a<ds::String<ConcurrentMemory>> workspace_path_;
      tbc::val_a<ds::String<ConcurrentMemory>> shell_;
      TerminalSize initial_size_;
      AgentScreenInference inference_;
      bool reset_needed_ = false;
      bool session_started_ = false;
      std::atomic<std::uint64_t> injected_submissions_{0};
      std::shared_ptr<PaneObserver> retired_next_;
    };

  }
}

// Interface: observation/processor.cppm
export {
  namespace telar::runtime {

    // The working directory a process probe reads, as Linux bounds a path.
    inline constexpr std::size_t probed_directory_bytes = 4096;

    template <typename Probe>
    concept PaneProcessProbe = ObservationService<Probe> && requires(Probe& probe, pid_t process) {
      { probe.directory(process) } noexcept -> std::same_as<FixedText<probed_directory_bytes>>;
    };

    // Generic over the caller's process probe and history sink, so it stays here whole.
    template <PaneProcessProbe Probe, HistoryEventSink History>
    class [[tbc::generic]] ObservationProcessor {
    public:
      // The panes one observation round reads.
      static constexpr std::size_t batch_capacity = 8;

      struct RequestEntry {
        std::uint64_t pane = 0;
        std::uint64_t generation = 0;
        AgentProvider provider = AgentProvider::unknown;
        std::shared_ptr<PaneObserver> observer;
        ProcessProbeRequest process_request{};
        bool probe_process = false;
        bool tracked_agent = false;
        std::uint64_t input_revision = 0;
      };

      struct Request {
        ds::Array<RequestEntry, batch_capacity> entries;
        std::size_t count = 0;
      };

      struct ResultEntry {
        std::uint64_t pane = 0;
        std::uint64_t generation = 0;
        std::uint64_t cwd_revision = 0;
        std::uint64_t input_revision = 0;
        std::shared_ptr<PaneObserver> observer;
        ScreenObservationResult screen{};
        ds::Option<ProcessProbeResult> process_result;
        bool process_recheck = false;
      };

      struct Result {
        ds::Array<ResultEntry, batch_capacity> entries;
        std::size_t count = 0;
      };

      inline explicit ObservationProcessor(const AgentManifests& manifests, Probe& probe, History& history) noexcept
          : manifests_(manifests),
            probe_(probe),
            history_(history) {}

      // The result carries the request's observers on.
      inline tbc::val_a<Result> observe(tbc::ref_a<Request> request) noexcept {
        Result result;
        typename Probe::Request process_request;

        for (const auto& entry : std::span{request.entries}.first(request.count)) {
          if (entry.probe_process) {
            process_request.panes.atMut(process_request.count++) = entry.process_request;
          }
        }

        ds::Option<typename Probe::Result> processes;

        if (process_request.count != 0) {
          processes = probe_.observe(process_request);
        }

        for (const auto& entry : std::span{request.entries}.first(request.count)) {
          auto& observed = result.entries.atMut(result.count++);

          observed.pane = entry.pane;
          observed.generation = entry.generation;
          observed.cwd_revision = entry.process_request.cwd_revision;
          observed.input_revision = entry.input_revision;
          observed.process_recheck = entry.process_request.recheck;
          observed.observer = entry.observer;
          const auto provider = processes ? attachProcess(entry, *processes, observed) : entry.provider;

          observed.screen = entry.observer->observe(manifests_, provider, history_, entry.tracked_agent || provider != AgentProvider::unknown);
          // Process snapshots follow the sealed input batch in time; applying their CWD first can rewrite a cd command's source directory.
          updateDirectory(entry, observed);
        }

        return result;
      }

      inline void stop() noexcept {}

    private:
      // The probe's reading of the entry's pane, its agent named as its manifest names it; the
      // agent it found, or the request's when it read none.
      inline AgentProvider attachProcess(const RequestEntry& entry, const Probe::Result& processes, ResultEntry& observed) {
        for (const auto& process : std::span{processes.panes}.first(processes.count)) {
          if (process.request.pane != entry.pane) {
            continue;
          }

          observed.process_result = process;
          if (const auto* manifest = manifests_.find(process.provider)) {
            observed.process_result.getMut().name.assign(manifest->displayName());
          }

          return process.provider;
        }

        return entry.provider;
      }

      // Moves the observer to the directory the probe read, or to the root process's when it read none.
      inline void updateDirectory(const RequestEntry& entry, const ResultEntry& observed) {
        if (observed.process_result && !observed.process_result->cwd.view().empty()) {
          entry.observer->updateDirectory(observed.process_result->cwd.view());
        } else if (!observed.process_result && entry.process_request.root > 0) {
          const auto directory = probe_.directory(entry.process_request.root);
          if (!directory.view().empty()) {
            entry.observer->updateDirectory(directory.view());
          }
        }
      }

      const AgentManifests& manifests_;
      Probe& probe_;
      History& history_;
    };

  }
}
