#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>

namespace telar::runtime {

template <std::size_t Capacity>
class Http2StreamIds {
public:
  bool start(std::uint32_t stream) noexcept {
    if (stream == 0 || std::ranges::find(ids_, stream) != ids_.end()) {
      return false;
    }

    const auto available = std::ranges::find(ids_, 0);
    if (available == ids_.end()) {
      return false;
    }
    *available = stream;
    ++count_;
    return true;
  }

  bool finish(std::uint32_t stream) noexcept {
    if (stream == 0) {
      return false;
    }

    const auto existing = std::ranges::find(ids_, stream);
    if (existing == ids_.end()) {
      return false;
    }
    *existing = 0;
    --count_;
    return true;
  }

  bool full() const noexcept { return count_ == Capacity; }
  std::uint32_t size() const noexcept { return count_; }

private:
  std::array<std::uint32_t, Capacity> ids_{};
  std::uint32_t count_ = 0;
};

}
