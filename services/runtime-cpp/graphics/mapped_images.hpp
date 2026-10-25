#pragma once

#include "../platform/mapped_region.hpp"
#include <array>
#include <atomic>
#include <mutex>

namespace telar::runtime {

class MappedImages {
public:
  bool adopt(const void *placeholder, MappedRegion &pixels) noexcept {
    const std::lock_guard lock{mutex_};
    if (placeholder == nullptr || !pixels) {
      return false;
    }

    Entry *available = nullptr;
    for (auto &entry : entries_) {
      if (entry.placeholder == placeholder) {
        return false;
      }
      if (entry.placeholder == nullptr && available == nullptr) {
        available = &entry;
      }
    }
    if (available == nullptr) {
      return false;
    }

    available->placeholder = placeholder;
    available->pixels = std::move(pixels);
    count_.fetch_add(1, std::memory_order_release);
    return true;
  }

  MappedRegion take(const void *placeholder) noexcept {
    if (count_.load(std::memory_order_acquire) == 0) {
      return {};
    }

    const std::lock_guard lock{mutex_};
    for (auto &entry : entries_) {
      if (entry.placeholder == placeholder) {
        entry.placeholder = nullptr;
        count_.fetch_sub(1, std::memory_order_release);
        return std::move(entry.pixels);
      }
    }
    return {};
  }

  std::span<const std::uint8_t> resolve(std::span<const std::uint8_t> bytes) const noexcept {
    if (count_.load(std::memory_order_acquire) == 0) {
      return bytes;
    }

    const std::lock_guard lock{mutex_};
    for (const auto &entry : entries_) {
      if (entry.placeholder == bytes.data()) {
        return entry.pixels.bytes();
      }
    }
    return bytes;
  }

private:
  struct Entry {
    const void *placeholder = nullptr;
    MappedRegion pixels;
  };

  static constexpr std::size_t capacity = 64;
  std::array<Entry, capacity> entries_;
  mutable std::mutex mutex_;
  std::atomic<std::size_t> count_{0};
};

}
