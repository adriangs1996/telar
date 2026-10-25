#pragma once

#include "../memory/allocator.hpp"
#include <algorithm>
#include <cstdint>
#include <span>

namespace telar::runtime {

template <Allocator Memory>
class CommandOutputTail {
public:
  static constexpr std::size_t capacity = 64 * 1024;

  explicit CommandOutputTail(Memory &memory, bool enabled)
      : bytes_(AllocatorRef<std::uint8_t, Memory>{memory}) {
    if (enabled) {
      enable();
    }
  }

  void enable() {
    bytes_.resize(capacity);
  }

  void append(std::span<const std::uint8_t> bytes) noexcept {
    if (bytes_.empty()) {
      return;
    }

    observed_ += std::min<std::uint64_t>(bytes.size(), UINT64_MAX - observed_);
    if (bytes.size() >= capacity) {
      std::copy(bytes.end() - capacity, bytes.end(), bytes_.begin());
      length_ = capacity;
      return;
    }

    if (length_ + bytes.size() > capacity) {
      const auto keep = std::min(capacity / 2, capacity - bytes.size());
      std::move(bytes_.begin() + length_ - keep, bytes_.begin() + length_, bytes_.begin());
      length_ = keep;
    }

    std::copy(bytes.begin(), bytes.end(), bytes_.begin() + length_);
    length_ += bytes.size();
  }

  std::span<const std::uint8_t> bytes() const noexcept {
    return std::span<const std::uint8_t>{bytes_}.first(length_);
  }

  std::uint64_t observed() const noexcept {
    return observed_;
  }

  void clear() noexcept {
    length_ = 0;
    observed_ = 0;
  }

private:
  Vector<std::uint8_t, Memory> bytes_;
  std::size_t length_ = 0;
  std::uint64_t observed_ = 0;
};

}
