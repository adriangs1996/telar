#pragma once

#include "tbc/view.hpp"
#include "telar_platform/mapped_region.hpp"
#include <array>
#include <atomic>
#include <mutex>

namespace telar::runtime {

// Mappings that stand in for placeholder allocations, shared by the threads that decode and draw
// images under its mutex. A mapping lives until its placeholder is deallocated.
class TBC_SHARED MappedImages {
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

  // The pixels standing in for a placeholder, which live as long as it does, or the bytes themselves.
  tbc::view<std::span<const std::uint8_t>, tbc::lt::a> resolve(tbc::view<std::span<const std::uint8_t>, tbc::lt::a> bytes) const noexcept {
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
  tbc::view<std::array<Entry, capacity>, tbc::lt::a> entries_;
  mutable std::mutex mutex_;
  std::atomic<std::size_t> count_{0};
};

}
