#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>

namespace telar::gui {

class CpuHistory {
public:
  static constexpr std::size_t capacity = 32;
  using Samples = std::array<std::uint8_t, capacity>;

  void push(std::uint8_t percent) noexcept {
    samples_[next_] = percent;
    next_ = (next_ + 1) % capacity;
    count_ = count_ < capacity ? count_ + 1 : capacity;
  }

  [[nodiscard]] std::span<const std::uint8_t> ordered(Samples &buffer) const noexcept {
    const auto start = (next_ + capacity - count_) % capacity;
    for (std::size_t index = 0; index < count_; ++index) {
      buffer[index] = samples_[(start + index) % capacity];
    }

    return std::span{buffer}.first(count_);
  }

private:
  Samples samples_{};
  std::size_t count_ = 0;
  std::size_t next_ = 0;
};

}
