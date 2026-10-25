#pragma once

#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <optional>
#include <type_traits>
#include <utility>

namespace telar::runtime {

struct TransferQueueMetrics {
  std::uint64_t queued = 0;
  std::uint64_t high_water = 0;
  std::uint64_t dropped = 0;
};

enum class ChannelPolicy { best_effort,
                           keep_oldest,
                           keep_newest };

template <typename Value, std::size_t Capacity, ChannelPolicy policy = ChannelPolicy::best_effort>
  requires std::is_nothrow_move_constructible_v<Value> && std::is_nothrow_swappable_v<Value>
class DropChannel {
  static_assert(Capacity != 0);

public:
  bool publish(Value value) noexcept {
    std::optional<Value> discarded;
    const auto lock = acquire();
    if (!lock.owns_lock() || closed_) {
      dropped_.fetch_add(1, std::memory_order_relaxed);
      return false;
    }

    if (count_ == Capacity) {
      dropped_.fetch_add(1, std::memory_order_relaxed);
      if constexpr (policy == ChannelPolicy::keep_newest) {
        discarded = take();
      } else {
        return false;
      }
    }

    slots_[(head_ + count_) % Capacity].emplace(std::move(value));
    ++count_;
    queued_.store(count_, std::memory_order_relaxed);
    high_water_.store(std::max(high_water_.load(std::memory_order_relaxed), static_cast<std::uint64_t>(count_)), std::memory_order_relaxed);
    ready_.notify_one();
    return true;
  }

  std::optional<Value> receive() {
    std::unique_lock lock{mutex_};
    ready_.wait(lock, [&] { return count_ != 0 || closed_; });
    return take();
  }

  std::optional<Value> tryReceive() noexcept {
    const auto lock = acquire();
    return lock.owns_lock() ? take() : std::nullopt;
  }

  void close() noexcept {
    std::array<std::optional<Value>, Capacity> discarded;
    {
      const std::lock_guard lock{mutex_};
      closed_ = true;
      discarded.swap(slots_);
      count_ = 0;
      head_ = 0;
      queued_.store(0, std::memory_order_relaxed);
    }
    ready_.notify_all();
  }

  TransferQueueMetrics metrics() const noexcept {
    return {queued_.load(std::memory_order_relaxed), high_water_.load(std::memory_order_relaxed), dropped_.load(std::memory_order_relaxed)};
  }

private:
  std::unique_lock<std::mutex> acquire() noexcept {
    if constexpr (policy == ChannelPolicy::best_effort) {
      return std::unique_lock{mutex_, std::try_to_lock};
    } else {
      return std::unique_lock{mutex_};
    }
  }

  std::optional<Value> take() noexcept {
    if (count_ == 0) {
      return std::nullopt;
    }
    auto value = std::move(slots_[head_]);
    slots_[head_].reset();
    head_ = (head_ + 1) % Capacity;
    --count_;
    queued_.store(count_, std::memory_order_relaxed);
    return value;
  }

  std::mutex mutex_;
  std::condition_variable ready_;
  std::array<std::optional<Value>, Capacity> slots_;
  std::size_t head_ = 0;
  std::size_t count_ = 0;
  bool closed_ = false;
  std::atomic<std::uint64_t> queued_{0};
  std::atomic<std::uint64_t> high_water_{0};
  std::atomic<std::uint64_t> dropped_{0};
};

}
