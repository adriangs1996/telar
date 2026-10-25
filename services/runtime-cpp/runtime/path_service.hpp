#pragma once

#include "../paths/query_task.hpp"
#include "../platform/observation_worker.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory, typename Index = PathIndex<Memory>>
  requires PathSearchIndex<Index, Memory>
class PathService {
public:
  explicit PathService(Memory &memory)
      : memory_(memory),
        slots_{emptySlot(memory), emptySlot(memory), emptySlot(memory), emptySlot(memory)} {}

  ~PathService() {
    stop();
  }

  void stop() noexcept {
    for (auto &slot : slots_) {
      if (slot) {
        slot->index.stop();
      }
    }
  }

  int descriptor() const noexcept {
    return completion_.descriptor();
  }

  void submit(std::uint64_t client, const FindPaths &request) {
    auto &slot = acquire(client);
    slot.used = ++clock_;
    slot.rebuild |= request.refresh || slot.wanted.root.view() != request.root;
    slot.wanted.assign(request);
    slot.pending = true;
    advance(slot);
  }

  template <typename Reply>
  bool tryQuery(std::uint64_t client, const FindPaths &request, Reply &reply) {
    auto *slot = find(client);
    if (slot == nullptr || slot->building || slot->querying || slot->rebuild || !slot->index.canQueryInline(request)) {
      return false;
    }

    slot->used = ++clock_;
    slot->wanted.assign(request);
    slot->index.queryPublished(request, reply);
    return true;
  }

  template <typename Consumer>
  void collect(Consumer &&consume) {
    completion_.drain();
    for (auto &owned : slots_) {
      if (!owned) {
        continue;
      }

      auto &slot = *owned;
      slot.build_worker.collect([&](bool) {
        slot.building = false;
        slot.pending |= slot.answered_partial && !slot.querying;
      });
      slot.query_worker.collect([&](const typename PathQueryTask<Memory, Index>::Result &result) {
        slot.querying = false;
        slot.answered_partial = !result.complete;
        if (!result.complete && slot.index.complete() && !slot.rebuild) {
          slot.pending = true;
        }
        if (!slot.abandoned) {
          consume(slot.client, ClientTag::find_paths, result.payload);
        }
      });

      if (slot.abandoned) {
        if (!slot.building && !slot.querying) {
          owned.reset();
        }
      } else {
        advance(slot);
      }
    }
  }

  void cancel(std::uint64_t client) noexcept {
    for (auto &slot : slots_) {
      if (!slot || slot->client != client) {
        continue;
      }

      slot->abandoned = true;
      slot->index.stop();
      completion_.notify();
      return;
    }
  }

private:
  struct Slot {
    explicit Slot(Memory &memory, CompletionSignal &completion, std::uint64_t client)
        : client(client),
          index(memory),
          build_task(index),
          query_task(memory, index),
          build_worker(build_task, &completion),
          query_worker(query_task, &completion) {}

    std::uint64_t client;
    std::uint64_t used = 0;
    OwnedPathQuery wanted;
    bool pending = false;
    bool rebuild = false;
    bool building = false;
    bool querying = false;
    bool answered_partial = false;
    bool abandoned = false;
    Index index;
    PathBuildTask<Index> build_task;
    PathQueryTask<Memory, Index> query_task;
    ObservationWorker<PathBuildTask<Index>> build_worker;
    ObservationWorker<PathQueryTask<Memory, Index>> query_worker;
  };

  static Owned<Slot, Memory> emptySlot(Memory &memory) noexcept {
    return {nullptr, AllocationDeleter<Slot, Memory>{memory}};
  }

  Slot *find(std::uint64_t client) const noexcept {
    for (const auto &slot : slots_) {
      if (slot && !slot->abandoned && slot->client == client) {
        return slot.get();
      }
    }
    return nullptr;
  }

  Slot &acquire(std::uint64_t client) {
    if (auto *slot = find(client)) {
      return *slot;
    }

    Owned<Slot, Memory> *selected = nullptr;
    for (auto &slot : slots_) {
      if (!slot) {
        selected = &slot;
        break;
      }
      if (!slot->building && !slot->querying && (selected == nullptr || slot->used < (*selected)->used)) {
        selected = &slot;
      }
    }
    if (selected == nullptr) {
      throw RequestError{FailureCode::resource_limit, "Every path picker slot is busy"};
    }

    selected->reset();
    *selected = makeOwned<Slot>(memory_, memory_, completion_, client);
    return **selected;
  }

  static void advance(Slot &slot) {
    if (slot.rebuild) {
      if (slot.building || slot.querying) {
        slot.index.stop();
        return;
      }

      slot.index.reset(slot.wanted.root.view());
      slot.rebuild = false;
      slot.answered_partial = false;
      slot.building = slot.build_worker.submit(true);
    }
    if (slot.pending && !slot.querying) {
      slot.querying = slot.query_worker.submit(slot.wanted);
      slot.pending = !slot.querying;
    }
  }

  Memory &memory_;
  CompletionSignal completion_;
  std::array<Owned<Slot, Memory>, 4> slots_;
  std::uint64_t clock_ = 0;
};

}
