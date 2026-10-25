#pragma once

#include "../agents/description_generator.hpp"
#include "../history/event.hpp"
#include "../platform/observation_worker.hpp"

namespace telar::runtime {

template <typename Agents>
concept DescriptionObserver = requires(Agents &agents, const DescriptionResult &result) {
  { agents.enableDescriptions(true) } noexcept -> std::same_as<void>;
  { agents.nextDescription() } -> std::same_as<std::optional<DescriptionRequest>>;
  { agents.completeDescription(result) } -> std::same_as<std::optional<HistorySessionTitle>>;
};

template <ConcurrentAllocator Memory, DescriptionObserver Agents, HistoryEventSink History>
class DescriptionService {
public:
  explicit DescriptionService(Memory &memory, Agents &agents, History &history, const DescriptionOptions &options)
      : agents_(agents),
        history_(history),
        generator_(memory, options) {
    agents_.enableDescriptions(!options.arguments.empty());
    if (!options.arguments.empty()) {
      worker_.emplace(generator_);
    }
  }

  void tick() {
    if (!worker_) {
      return;
    }

    collect();
    if (!pending_) {
      if (auto request = agents_.nextDescription()) {
        pending_ = worker_->submit(*request);
      }
    }
  }

  void collect() {
    if (!pending_) {
      return;
    }

    worker_->collect([&](const DescriptionResult &result) {
      pending_ = false;
      if (const auto title = agents_.completeDescription(result)) {
        history_.recordHistory(HistoryEventView{.kind = HistoryEventKind::session_title, .session = {}, .title = *title});
      }
    });
  }

  int descriptor() const noexcept {
    return worker_ ? worker_->descriptor() : -1;
  }

private:
  Agents &agents_;
  History &history_;
  DescriptionGenerator<Memory> generator_;
  std::optional<ObservationWorker<DescriptionGenerator<Memory>>> worker_;
  bool pending_ = false;
};

}
