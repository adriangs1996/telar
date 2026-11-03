#pragma once

#include "agent.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/request_error.hpp"

namespace telar::runtime {

template <Allocator Memory>
class AgentRegistry {
public:
  explicit AgentRegistry(Memory &memory)
      : memory_(memory),
        records_(AllocatorRef<Owned<Agent, Memory>, Memory>{memory}) {
    records_.reserve(capacity);
  }

  Agent *find(std::uint64_t pane, std::uint64_t generation) const noexcept {
    for (const auto &agent : records_) {
      if (agent->pane == pane && agent->generation == generation) {
        return agent.get();
      }
    }

    return nullptr;
  }

  Agent &ensure(std::uint64_t pane, std::uint64_t generation) {
    if (auto *existing = find(pane, generation)) {
      return *existing;
    }
    if (records_.size() == capacity) {
      throw RequestError{FailureCode::resource_limit, "Agent capacity reached"};
    }

    records_.push_back(makeOwned<Agent>(memory_, pane, generation));
    return *records_.back();
  }

  template <typename Predicate>
  void removeIf(Predicate &&predicate) {
    if (std::erase_if(records_, [&](const auto &agent) { return predicate(*agent); }) != 0) {
      changed();
    }
  }

  auto records() const noexcept {
    return std::span{records_};
  }

  void changed() noexcept {
    ++revision_;
  }

  std::uint64_t revision() const noexcept {
    return revision_;
  }

  static constexpr std::size_t capacity = 64;

private:
  Memory &memory_;
  Vector<Owned<Agent, Memory>, Memory> records_;
  std::uint64_t revision_ = 1;
};

}
