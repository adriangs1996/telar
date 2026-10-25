#pragma once

#include "../platform/observation_worker.hpp"
#include "../platform/process_probe.hpp"
#include "pane_observer.hpp"
#include <memory>

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

  explicit ObservationProcessor(const AgentManifests &manifests, Probe &probe, History &history) noexcept
      : manifests_(manifests),
        probe_(probe),
        history_(history) {}

  Result observe(const Request &request) noexcept {
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

  void stop() noexcept {}

private:
  const AgentManifests &manifests_;
  Probe &probe_;
  History &history_;
};

}
