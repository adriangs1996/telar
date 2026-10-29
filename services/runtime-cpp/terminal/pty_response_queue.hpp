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

  bool push(std::span<const std::uint8_t> response) noexcept {
    const std::lock_guard lock{mutex_};
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
    return count_ != message_capacity && byte_count_ < total_byte_capacity;
  }

private:
  bool append(std::span<const std::uint8_t> response, std::shared_ptr<const void> owner) noexcept {
    if (count_ == message_capacity || response.size() > total_byte_capacity - byte_count_ || (response.size() > message_byte_capacity && !owner)) {
      return false;
    }

    const auto index = (head_ + count_) % message_capacity;
    if (owner) {
      owned_[index] = std::move(owner);
      views_[index] = response;
    } else if (!response.empty()) {
      std::memcpy(bytes_[index].data(), response.data(), response.size());
    }
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

  std::span<const std::uint8_t> readable() const noexcept {
    return peek().value_or(std::span<const std::uint8_t>{});
  }

  void consume(std::size_t bytes) noexcept {
    const std::lock_guard lock{mutex_};
    assert(count_ != 0 && bytes <= lengths_[head_] - offset_);
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

  bool empty() const noexcept {
    const std::lock_guard lock{mutex_};
    return count_ == 0;
  }

  void clear() noexcept {
    const std::lock_guard lock{mutex_};
    for (auto &owner : owned_) {
      owner.reset();
    }
    head_ = 0;
    count_ = 0;
    offset_ = 0;
    byte_count_ = 0;
  }

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
};

}
