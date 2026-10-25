#pragma once

#include "../diagnostics/line.hpp"
#include <array>
#include <cassert>
#include <cstring>
#include <mutex>
#include <optional>
#include <span>

namespace telar::runtime {

class PtyResponseQueue {
public:
  static constexpr std::size_t message_capacity = 64;
  static constexpr std::size_t message_byte_capacity = 1024;

  struct Snapshot {
    std::size_t messages;
    std::size_t bytes;
    std::uint64_t dropped;
  };

  // Response bytes are initialized when a slot is published, without clearing the entire queue at construction.
  PtyResponseQueue() noexcept {}

  bool push(std::span<const std::uint8_t> response) noexcept {
    const std::lock_guard lock{mutex_};
    if (response.size() > message_byte_capacity || count_ == message_capacity) {
      diagnostics::accumulate(dropped_);
      return false;
    }

    const auto index = (head_ + count_) % message_capacity;
    if (!response.empty()) {
      std::memcpy(bytes_[index].data(), response.data(), response.size());
    }
    lengths_[index] = static_cast<std::uint16_t>(response.size());
    byte_count_ += response.size();
    ++count_;
    return true;
  }

  // A single consumer may borrow the head until consume or clear; producers only append behind it.
  std::optional<std::span<const std::uint8_t>> peek() const noexcept {
    const std::lock_guard lock{mutex_};
    if (count_ == 0) {
      return std::nullopt;
    }

    return std::span{bytes_[head_]}.subspan(offset_, lengths_[head_] - offset_);
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
  std::array<std::uint16_t, message_capacity> lengths_;
  std::size_t head_ = 0;
  std::size_t count_ = 0;
  std::size_t offset_ = 0;
  std::size_t byte_count_ = 0;
  std::uint64_t dropped_ = 0;
};

}
