#pragma once

#include "quota.hpp"
#include "telar_base/memory/erasing_allocator.hpp"
#include <cstdint>
#include <cstring>
#include <span>

namespace telar::runtime {

template <Allocator Memory>
class CaptureBuffer {
public:
  explicit CaptureBuffer(Memory &memory, CaptureQuota &quota, std::size_t limit) noexcept : memory_(memory), quota_(quota), limit_(limit) {}

  ~CaptureBuffer() {
    memory_.deallocate(storage_, capacity_, alignof(std::uint8_t));
    quota_.release(capacity_);
  }

  CaptureBuffer(const CaptureBuffer &) = delete;
  CaptureBuffer &operator=(const CaptureBuffer &) = delete;

  std::size_t append(std::span<const std::uint8_t> input) noexcept {
    const auto allowed = std::min(input.size(), limit_ - size_);
    const auto accepted = reserveAdditional(allowed);
    if (accepted != 0) {
      std::memcpy(storage_ + size_, input.data(), accepted);
      size_ += accepted;
    }
    truncated = truncated || accepted != input.size();
    return accepted;
  }

  void reset() noexcept {
    eraseSensitive(storage_, size_);
    size_ = 0;
    truncated = false;
  }

  std::span<const std::uint8_t> bytes() const noexcept { return {storage_, size_}; }
  std::size_t size() const noexcept { return size_; }
  std::size_t capacity() const noexcept { return capacity_; }
  std::size_t remaining() const noexcept { return limit_ - size_; }

  bool truncated = false;

private:
  std::size_t grownCapacity(std::size_t needed) const noexcept {
    auto capacity = std::min(limit_, std::max(initial_capacity, capacity_));
    while (capacity < needed) {
      capacity = capacity > limit_ / 2 ? limit_ : capacity * 2;
    }
    return capacity;
  }

  std::size_t reserveAdditional(std::size_t bytes) noexcept {
    if (bytes <= capacity_ - size_) {
      return bytes;
    }

    // The old allocation remains charged until the replacement has been copied.
    const auto replacement_capacity = quota_.reserveAtMost(grownCapacity(size_ + bytes));
    if (replacement_capacity <= capacity_) {
      quota_.release(replacement_capacity);
      return capacity_ - size_;
    }

    auto *replacement = static_cast<std::uint8_t *>(memory_.allocate(replacement_capacity, alignof(std::uint8_t)));
    if (replacement == nullptr) {
      quota_.release(replacement_capacity);
      return capacity_ - size_;
    }

    if (size_ != 0) {
      std::memcpy(replacement, storage_, size_);
    }
    memory_.deallocate(storage_, capacity_, alignof(std::uint8_t));
    quota_.release(capacity_);
    storage_ = replacement;
    capacity_ = replacement_capacity;
    return std::min(bytes, capacity_ - size_);
  }

  static constexpr std::size_t initial_capacity = 256;
  ErasingAllocator<Memory> memory_;
  CaptureQuota &quota_;
  const std::size_t limit_;
  std::uint8_t *storage_ = nullptr;
  std::size_t size_ = 0;
  std::size_t capacity_ = 0;
};

}
