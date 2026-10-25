#pragma once

#include "../memory/slot_indexes.hpp"
#include "exchange.hpp"
#include <limits>

namespace telar::runtime {

template <Allocator Memory>
class CaptureJoiner {
public:
  using Half = typename CapturedExchange<Memory>::Half;
  enum class State {
    pending,
    complete,
    partial,
    full
  };

  struct Result {
    State state;
    CapturedExchange<Memory> exchange;
  };

  explicit CaptureJoiner(Memory &memory, std::chrono::milliseconds timeout) noexcept : memory_(memory), timeout_ms_(timeout.count()) {}

  Result push(std::int64_t now_ms, Half half) noexcept {
    Result result{State::pending, CapturedExchange<Memory>{memory_}};
    const auto existing = find(half->key);
    if (existing) {
      auto &entry = *slots_[*existing];
      if (entry.half->side == half->side) {
        result.state = State::partial;
      } else {
        result.state = State::complete;
        result.exchange.include(std::move(entry.half));
        slots_[*existing].reset();
        occupied_.erase(*existing);
      }
      result.exchange.include(std::move(half));
      return result;
    }

    const auto available = occupied_.firstUnused();
    if (!available) {
      result.state = State::full;
      result.exchange.include(std::move(half));
      return result;
    }

    const auto maximum_time = std::numeric_limits<std::int64_t>::max();
    const auto deadline = now_ms > maximum_time - timeout_ms_ ? maximum_time : now_ms + timeout_ms_;
    slots_[*available].emplace(std::move(half), deadline);
    occupied_.insert(*available);
    return result;
  }

  std::optional<CapturedExchange<Memory>> expire(std::int64_t now_ms) noexcept {
    std::optional<std::size_t> expired;
    occupied_.forEach([&](std::size_t index) {
      if (!expired && slots_[index]->expires_at_ms <= now_ms) {
        expired = index;
      }
    });
    if (!expired) {
      return std::nullopt;
    }

    CapturedExchange<Memory> result{memory_};
    result.include(std::move(slots_[*expired]->half));
    slots_[*expired].reset();
    occupied_.erase(*expired);
    return result;
  }

  static constexpr std::size_t capacity = 256;

private:
  struct Entry {
    Half half;
    std::int64_t expires_at_ms;
  };

  std::optional<std::size_t> find(CaptureKey key) const noexcept {
    std::optional<std::size_t> found;
    occupied_.forEach([&](std::size_t index) {
      if (slots_[index]->half->key == key) {
        found = index;
      }
    });
    return found;
  }

  Memory &memory_;
  std::int64_t timeout_ms_;
  std::array<std::optional<Entry>, capacity> slots_;
  SlotIndexes<capacity> occupied_;
};

}
