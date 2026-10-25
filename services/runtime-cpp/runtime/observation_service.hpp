#pragma once

#include "../agents/agent.hpp"
#include "../model/runtime_model.hpp"
#include "../observation/processor.hpp"
#include "../platform/observation_worker.hpp"

namespace telar::runtime {

template <typename Agents, typename Memory>
concept AgentObservationSink = Allocator<Memory> && requires(Agents &agents, Pane<Memory> &pane, AgentSignal signal, ObservationTime time) {
  { agents.find(pane.id, pane.generation) } -> std::convertible_to<const Agent *>;
  { agents.observeScreen(pane, signal, time) } -> std::same_as<void>;
  { agents.observeProcess(pane, ProcessProbeResult{}) } -> std::same_as<void>;
};

template <typename Limits>
concept ObservationLimitSink = requires(Limits &limits, const LimitReach &reach) {
  { limits.report(reach) } -> std::same_as<void>;
};

template <ConcurrentAllocator Memory, typename Agents, ObservationLimitSink Limits, PaneProcessProbe Probe, HistoryEventSink History>
  requires AgentObservationSink<Agents, Memory>
class PaneObservationService {
  using Processor = ObservationProcessor<Memory, Probe, History>;

public:
  explicit PaneObservationService(RuntimeModel<Memory> &model, Agents &agents, Limits &limits, Probe &probe, History &history)
      : model_(model),
        agents_(agents),
        limits_(limits),
        processor_(model.manifests, probe, history),
        worker_(processor_) {}

  void refresh() {
    collect();
    if (pending_) {
      return;
    }

    typename Processor::Request request;
    enqueueRetired(request);
    const auto panes = model_.panes.items();
    for (std::size_t visited = 0; visited < panes.size() && request.count < request.entries.size(); ++visited) {
      const auto slot = next_slot_++ % panes.size();
      auto *pane = panes[slot];
      if (pane == nullptr) {
        continue;
      }

      enqueue(request, *pane);
      if (request.count == request.entries.size()) {
        break;
      }
    }

    if (request.count != 0) {
      pending_ = worker_.submit(request);
    }
  }

  void observe(Pane<Memory> &pane) {
    collect();
    if (pending_) {
      return;
    }

    typename Processor::Request request;
    enqueue(request, pane);
    if (request.count != 0) {
      pending_ = worker_.submit(request);
    }
  }

  void collect() {
    if (!pending_) {
      return;
    }

    worker_.collect([&](const typename Processor::Result &result) { apply(result); });
  }

  void finish() noexcept {
    for (;;) {
      worker_.wait([&](const typename Processor::Result &result) {
        pending_ = false;
        for (const auto &entry : std::span{result.entries}.first(result.count)) {
          entry.observer->complete();
        }
      });

      typename Processor::Request request;
      for (auto *pane : model_.panes.items()) {
        if (pane != nullptr && pane->observer->seal()) {
          request.entries[request.count++].observer = pane->observer;
          if (request.count == request.entries.size()) {
            break;
          }
        }
      }

      enqueueRetired(request);
      if (request.count == 0) {
        return;
      }

      pending_ = worker_.submit(request);
    }
  }

  int descriptor() const noexcept {
    return worker_.descriptor();
  }

private:
  void apply(const typename Processor::Result &result) {
    pending_ = false;
    for (const auto &entry : std::span{result.entries}.first(result.count)) {
      entry.observer->complete();
    }

    for (const auto &entry : std::span{result.entries}.first(result.count)) {
      TELAR_DIAGNOSTIC(model_.metrics.observation.merge(entry.screen.metrics));
      if (entry.screen.failed) {
        limits_.report(LimitReach{.name = "history.observation_failures", .noun = "failed observations", .route = "history"});
      }

      auto *pane = model_.panes.find(entry.pane);
      if (pane == nullptr || pane->generation != entry.generation || pane->exit_status) {
        continue;
      }

      if (entry.process_recheck) {
        pane->process_recheck_running = false;
        ++pane->process_rechecks;
      }

      pane->shell_markers = entry.screen.shell_markers && !entry.screen.failed;
      if (pane->input_revision == entry.input_revision) {
        pane->needs_foreground_observation = entry.screen.needs_foreground;
      }
      const auto directory = entry.observer->observedDirectory();
      if (pane->cwd_revision == entry.cwd_revision && !directory.empty() && pane->cwd != directory) {
        pane->cwd.assign(directory);
        ++pane->cwd_revision;
      }

      if (entry.process_result && entry.process_result->inspected) {
        TELAR_DIAGNOSTIC(diagnostics::accumulate(model_.metrics.agent_process_inspections));
        TELAR_DIAGNOSTIC(diagnostics::accumulate(model_.metrics.agent_process_misses, entry.process_result->provider == AgentProvider::unknown));
        applyProcess(*pane, *entry.process_result);
      }

      if (entry.screen.signal) {
        agents_.observeScreen(*pane, *entry.screen.signal, entry.screen.time);
      }
    }
  }

  void enqueueRetired(typename Processor::Request &request) noexcept {
    auto *link = &model_.retired_observers;
    while (*link && request.count < request.entries.size()) {
      auto &observer = **link;
      if (observer.idle()) {
        auto next = std::move(observer.retired_next);
        *link = std::move(next);
        --model_.retired_observer_count;
        continue;
      }

      if (observer.seal()) {
        request.entries[request.count++].observer = *link;
      }

      link = &observer.retired_next;
    }
  }

  void enqueue(typename Processor::Request &request, Pane<Memory> &pane) {
    if (auto drop = pane.observer->takeDrop()) {
      limits_.report(*drop);
    }

    const bool probe_process = !pane.exit_status;
    if (!pane.observer->seal(!pane.exit_status && pane.process_recheck_requested)) {
      return;
    }

    request.entries[request.count++] = {.pane = pane.id, .generation = pane.generation, .provider = AgentProvider::unknown, .observer = pane.observer, .probe_process = probe_process};
    auto &entry = request.entries[request.count - 1];
    entry.input_revision = pane.input_revision;
    entry.process_request = {pane.id, pane.generation, pane.cwd_revision, pane.process->processId(), 0};
    entry.process_request.cache = pane.process_cache;
    if (const auto *agent = agents_.find(pane.id, pane.generation)) {
      entry.provider = agent->provider;
      entry.tracked_agent = true;
    }

    if (probe_process) {
      entry.process_request.discover_foreground = model_.panes.size() == 1;
      if (!entry.process_request.discover_foreground) {
        entry.process_request.foreground = pane.process->foregroundProcessGroup().value_or(0);
      }

      entry.process_request.recheck = pane.process_recheck_requested;
      pane.process_recheck_running = pane.process_recheck_requested;
      pane.process_recheck_requested = false;
    }
  }

  void applyProcess(Pane<Memory> &pane, const ProcessProbeResult &observation) {
    if (pane.generation != observation.request.generation || pane.exit_status || pane.process->processId() != observation.request.root || pane.process->foregroundProcessGroup().value_or(0) != observation.request.foreground) {
      return;
    }

    pane.process_cache = observation.cache;
    if (!observation.name.view().empty() && pane.foreground.view() != observation.name.view()) {
      pane.foreground = observation.name;
      ++pane.foreground_revision;
    }

    agents_.observeProcess(pane, observation);
  }

  RuntimeModel<Memory> &model_;
  Agents &agents_;
  Limits &limits_;
  Processor processor_;
  ObservationWorker<Processor> worker_;
  std::size_t next_slot_ = 0;
  bool pending_ = false;
};

}
