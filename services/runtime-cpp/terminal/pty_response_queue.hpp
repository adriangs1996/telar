#pragma once

#include "../diagnostics/line.hpp"
#include <array>
#include <cassert>
#include <cstring>
#include <mutex>
#include <memory>
#include <optional>
#include <span>

namespace telar::runtime {

class PtyResponseQueue {
public:
  static constexpr std::size_t message_capacity = 64;
  static constexpr std::size_t message_byte_capacity = 1024;
  static constexpr std::size_t total_byte_capacity = 2 * 1024 * 1024;

  struct Snapshot {
    std::size_t messages;
    std::size_t bytes;
    std::uint64_t dropped;
  };

  // Response bytes are initialized when a slot is published, without clearing the entire queue at construction.
  PtyResponseQueue() noexcept {}

  // A controller batches consecutive native replies under one lock. It must
  // release this lease before any backend write or callback can produce data.
  class Producer {
  public:
    explicit Producer(PtyResponseQueue &queue) : queue_(queue), lock_(queue.mutex_, std::defer_lock) {}

    bool tryPush(std::span<const std::uint8_t> response) noexcept {
      if (!acquire()) {
        return false;
      }
      return queue_.append(response, {});
    }

    template <std::size_t Length>
    bool tryPushFixed(const std::array<std::uint8_t, Length> &response) noexcept {
      static_assert(Length <= message_byte_capacity);
      if (!acquire()) {
        return false;
      }
      return queue_.append(response, {});
    }

    bool tryPushOwned(std::span<const std::uint8_t> response, std::shared_ptr<const void> owner) noexcept {
      if (!acquire()) {
        return false;
      }
      return queue_.append(response, std::move(owner));
    }

    void release() noexcept {
      if (lock_.owns_lock()) {
        lock_.unlock();
      }
    }

  private:
    bool acquire() {
      if (!lock_.owns_lock()) {
        lock_.lock();
        if (queue_.priority_workers_ != 0) {
          lock_.unlock();
          return false;
        }
      }
      return true;
    }

    PtyResponseQueue &queue_;
    std::unique_lock<std::mutex> lock_;
  };

  struct Batch {
    std::span<const std::span<const std::uint8_t>> first;
    std::span<const std::span<const std::uint8_t>> second;
    std::size_t offset = 0;
    std::size_t count = 0;
    std::size_t bytes = 0;

    std::span<const std::uint8_t> message(std::size_t index) const noexcept {
      assert(index < count);
      const auto value = index < first.size() ? first[index] : second[index - first.size()];
      return value.subspan(index == 0 ? offset : 0);
    }
  };

  bool push(std::span<const std::uint8_t> response) noexcept {
    const std::lock_guard lock{mutex_};
    if (closed_) {
      return false;
    }
    if (!append(response, {})) {
      diagnostics::accumulate(dropped_);
      return false;
    }

    return true;
  }

  bool tryPush(std::span<const std::uint8_t> response) noexcept {
    const std::lock_guard lock{mutex_};
    return append(response, {});
  }

  // Large replies retain immutable allocator-owned storage as one message, so
  // other producers cannot interleave bytes in the middle of a control string.
  bool tryPushOwned(std::span<const std::uint8_t> response, std::shared_ptr<const void> owner) noexcept {
    const std::lock_guard lock{mutex_};
    return append(response, std::move(owner));
  }

  bool hasCapacity() const noexcept {
    const std::lock_guard lock{mutex_};
    return !closed_ && count_ != message_capacity && byte_count_ < total_byte_capacity;
  }

  bool hasCapacityFor(std::size_t bytes) const noexcept {
    const std::lock_guard lock{mutex_};
    return !closed_ && count_ != message_capacity && bytes <= total_byte_capacity - byte_count_;
  }

  bool closed() const noexcept {
    const std::lock_guard lock{mutex_};
    return closed_;
  }

  // A retained worker ACK owns the next free slot. Native producers yield
  // their lease while the worker drains, avoiding starvation under query load.
  bool retainWorkerPriority() noexcept {
    const std::lock_guard lock{mutex_};
    if (closed_) {
      return false;
    }
    ++priority_workers_;
    return true;
  }

  void releaseWorkerPriority() noexcept {
    const std::lock_guard lock{mutex_};
    assert(priority_workers_ != 0);
    --priority_workers_;
  }

private:
  bool append(std::span<const std::uint8_t> response, std::shared_ptr<const void> owner) noexcept {
    if (closed_ || count_ == message_capacity || response.size() > total_byte_capacity - byte_count_ || (response.size() > message_byte_capacity && !owner)) {
      return false;
    }

    const auto index = (head_ + count_) % message_capacity;
    if (owner) {
      owned_[index] = std::move(owner);
    } else if (!response.empty()) {
      std::memcpy(bytes_[index].data(), response.data(), response.size());
    }
    views_[index] = owned_[index] ? response : std::span<const std::uint8_t>{bytes_[index]}.first(response.size());
    lengths_[index] = static_cast<std::uint32_t>(response.size());
    byte_count_ += response.size();
    ++count_;
    return true;
  }

public:
  // A single consumer may borrow the head until consume or clear; producers only append behind it.
  std::optional<std::span<const std::uint8_t>> peek() const noexcept {
    const std::lock_guard lock{mutex_};
    if (count_ == 0) {
      return std::nullopt;
    }

    const auto head = owned_[head_] ? views_[head_] : std::span<const std::uint8_t>{bytes_[head_]}.first(lengths_[head_]);
    return head.subspan(offset_);
  }

  Batch peekBatch() const noexcept {
    const std::lock_guard lock{mutex_};
    const auto first_count = std::min(count_, message_capacity - head_);
    const auto entries = std::span{views_};
    return Batch{
        .first = entries.subspan(head_, first_count),
        .second = entries.first(count_ - first_count),
        .offset = offset_,
        .count = count_,
        .bytes = byte_count_,
    };
  }

  // The batch borrows slot metadata and payload until the single consumer
  // consumes or clears. Producers publish exclusively behind its fixed prefix;
  // wrapping never overwrites an admitted slot before that consumer releases it.
  void consumeBytes(std::size_t bytes) noexcept {
    const std::lock_guard lock{mutex_};
    assert(bytes <= byte_count_);
    while (count_ != 0) {
      const auto remaining = lengths_[head_] - offset_;
      const auto count = std::min<std::size_t>(remaining, bytes);
      consumeHead(count);
      bytes -= count;
      if (count < remaining || (bytes == 0 && (count_ == 0 || lengths_[head_] != 0))) {
        break;
      }
    }
  }

  std::span<const std::uint8_t> readable() const noexcept {
    return peek().value_or(std::span<const std::uint8_t>{});
  }

  void consume(std::size_t bytes) noexcept {
    const std::lock_guard lock{mutex_};
    assert(count_ != 0 && bytes <= lengths_[head_] - offset_);
    consumeHead(bytes);
  }

private:
  void consumeHead(std::size_t bytes) noexcept {
    offset_ += bytes;
    byte_count_ -= bytes;
    if (offset_ == lengths_[head_]) {
      owned_[head_].reset();
      views_[head_] = {};
      head_ = (head_ + 1) % message_capacity;
      offset_ = 0;
      --count_;
    }
  }

public:
  bool empty() const noexcept {
    const std::lock_guard lock{mutex_};
    return count_ == 0;
  }

  // Workers may reject future publication, but only the single consumer may
  // clear storage: it can still be borrowing an owned reply for writev.
  void stopProducing() noexcept {
    const std::lock_guard lock{mutex_};
    closed_ = true;
  }

  // Closing permanently cancels this pane generation, including late worker callbacks.
  void close() noexcept {
    const std::lock_guard lock{mutex_};
    closed_ = true;
    clearLocked();
  }

  void clear() noexcept {
    const std::lock_guard lock{mutex_};
    clearLocked();
  }

private:
  void clearLocked() noexcept {
    for (auto &owner : owned_) {
      owner.reset();
    }
    head_ = 0;
    count_ = 0;
    offset_ = 0;
    byte_count_ = 0;
  }

public:
  Snapshot snapshot() const noexcept {
    const std::lock_guard lock{mutex_};
    return {count_, byte_count_, dropped_};
  }

private:
  mutable std::mutex mutex_;
  std::array<std::array<std::uint8_t, message_byte_capacity>, message_capacity> bytes_;
  std::array<std::uint32_t, message_capacity> lengths_;
  std::array<std::shared_ptr<const void>, message_capacity> owned_;
  std::array<std::span<const std::uint8_t>, message_capacity> views_;
  std::size_t head_ = 0;
  std::size_t count_ = 0;
  std::size_t offset_ = 0;
  std::size_t byte_count_ = 0;
  std::uint64_t dropped_ = 0;
  bool closed_ = false;
  std::size_t priority_workers_ = 0;
};

}
