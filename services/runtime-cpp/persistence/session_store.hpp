#pragma once

#include "../diagnostics/trace.hpp"
#include "../platform/observation_worker.hpp"
#include "file_store.hpp"
#include "options.hpp"
#include "restore.hpp"
#include "snapshot.hpp"

namespace telar::runtime::checkpoint {

template <ConcurrentAllocator Memory, EventLoop Poller, AgentSource Agents, HistoryEventSink History = DiscardedHistory>
class SessionStore {
  using Clock = std::chrono::steady_clock;

public:
  explicit SessionStore(Memory &memory, RuntimeModel<Memory> &model, PaneService<Memory, Poller, History> &panes, ClientLayouts<Memory> &layouts, const Agents &agents)
      : memory_(memory),
        model_(model),
        panes_(panes),
        layouts_(layouts),
        snapshot_(model, layouts, agents),
        buffer_(AllocatorRef<Byte, Memory>{memory}) {}

  ~SessionStore() {
    if (worker_) {
      worker_->wait([](int) {});
    }
  }

  void configure(Options options) {
    if (options.path.empty()) {
      return;
    }

    file_.emplace(memory_, options.path);
    try {
      if (file_->load(buffer_)) {
        Reader validation{buffer_};
        validation.read([](const auto &) {});
        Restore restore{memory_, model_, panes_, layouts_, options.resume_agents};
        restore.apply(buffer_);
      }
    } catch (const EncodingError &) {
      file_->quarantine();
    } catch (const std::exception &) {
    }

    buffer_.resize(maximum_bytes);
    worker_.emplace(*file_);
    dirty_ = true;
    due_ = Clock::now() + debounce;
  }

  std::chrono::nanoseconds tick(Clock::time_point now) {
    if (!worker_) {
      return std::chrono::seconds{1};
    }

    collect();
    if (snapshot_.changed()) {
      dirty_ = true;
      due_ = now + debounce;
    }

    if (!dirty_ || pending_) {
      return std::chrono::seconds{1};
    }
    if (now < due_) {
      return due_ - now;
    }

    try {
      TELAR_TRACE("checkpoint.encode");
      const auto bytes = snapshot_.encode(buffer_);
      pending_ = worker_->submit(bytes);
      dirty_ = !pending_;
    } catch (const std::exception &) {
      dirty_ = false;
      ++encoding_failures;
    }

    return std::chrono::seconds{1};
  }

  void collect() {
    if (worker_) {
      worker_->collect([&](int error) { completed(error); });
    }
  }

  void finish() noexcept {
    if (!worker_) {
      return;
    }

    try {
      worker_->wait([&](int error) { completed(error); });
      if (snapshot_.changed() || dirty_) {
        const auto bytes = snapshot_.encode(buffer_);
        if (worker_->submit(bytes)) {
          worker_->wait([&](int error) { completed(error); });
        }
      }
    } catch (const std::exception &) {
      ++encoding_failures;
    }
  }

  int descriptor() const noexcept {
    return worker_ ? worker_->descriptor() : -1;
  }

  std::uint64_t write_failures = 0;
  std::uint64_t encoding_failures = 0;

private:
  static constexpr std::chrono::milliseconds debounce{500};

  void completed(int error) {
    pending_ = false;
    if (error != 0) {
      ++write_failures;
      dirty_ = true;
      due_ = Clock::now() + debounce;
    }
  }

  Memory &memory_;
  RuntimeModel<Memory> &model_;
  PaneService<Memory, Poller, History> &panes_;
  ClientLayouts<Memory> &layouts_;
  Snapshot<Memory, Agents> snapshot_;
  Vector<Byte, Memory> buffer_;
  std::optional<FileStore<Memory>> file_;
  std::optional<ObservationWorker<FileStore<Memory>>> worker_;
  Clock::time_point due_{};
  bool dirty_ = false;
  bool pending_ = false;
};

}
