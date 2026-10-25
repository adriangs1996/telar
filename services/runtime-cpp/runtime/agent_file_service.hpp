#pragma once

#include "../agents/session_file_reader.hpp"
#include "../platform/observation_worker.hpp"

namespace telar::runtime {

template <typename Agents>
concept SessionFileObserver = requires(Agents &agents, const SessionFileResult &result, std::chrono::steady_clock::time_point now) {
  { agents.nextSessionFile(now) } -> std::same_as<std::optional<SessionFileRequest>>;
  { agents.completeSessionFile(result, now) } -> std::same_as<void>;
};

template <ConcurrentAllocator Memory, SessionFileObserver Agents>
class AgentFileService {
public:
  explicit AgentFileService(Memory &memory, Agents &agents)
      : agents_(agents),
        reader_(memory),
        worker_(reader_) {}

  void tick(std::chrono::steady_clock::time_point now) {
    collect();
    if (!pending_) {
      if (const auto request = agents_.nextSessionFile(now)) {
        pending_ = worker_.submit(*request);
      }
    }
  }

  void collect() {
    if (!pending_) {
      return;
    }

    worker_.collect([&](const SessionFileResult &result) {
      pending_ = false;
      agents_.completeSessionFile(result, std::chrono::steady_clock::now());
    });
  }

  int descriptor() const noexcept {
    return worker_.descriptor();
  }

private:
  Agents &agents_;
  SessionFileReader<Memory> reader_;
  ObservationWorker<SessionFileReader<Memory>> worker_;
  bool pending_ = false;
};

}
