#pragma once

#include "../memory/allocator.hpp"
#include "mapped_images.hpp"

namespace telar::runtime {

class MediaBudget {
public:
  explicit MediaBudget(std::size_t limit) noexcept
      : limit_(limit) {}

  bool reserve(std::size_t &pane_used, std::size_t pane_limit, std::size_t bytes) noexcept {
    const std::lock_guard lock{mutex_};
    if (bytes > pane_limit - pane_used || bytes > limit_ - used_) {
      return false;
    }
    pane_used += bytes;
    used_ += bytes;
    return true;
  }

  void release(std::size_t &pane_used, std::size_t bytes) noexcept {
    const std::lock_guard lock{mutex_};
    pane_used -= bytes;
    used_ -= bytes;
  }

  std::size_t used() const noexcept {
    const std::lock_guard lock{mutex_};
    return used_;
  }

  std::size_t usedBy(const std::size_t &pane_used) const noexcept {
    const std::lock_guard lock{mutex_};
    return pane_used;
  }

private:
  mutable std::mutex mutex_;
  std::size_t limit_;
  std::size_t used_ = 0;
};

template <Allocator Upstream>
class MediaAllocator {
public:
  static constexpr bool thread_safe = ConcurrentAllocator<Upstream>;

  explicit MediaAllocator(Upstream &upstream, MediaBudget &budget, std::size_t pane_limit) noexcept
      : upstream_(upstream),
        budget_(budget),
        limit_(pane_limit) {}

  MediaAllocator(const MediaAllocator &) = delete;
  MediaAllocator &operator=(const MediaAllocator &) = delete;

  void *allocate(std::size_t size, std::size_t alignment) noexcept {
    if (!reserve(size)) {
      return nullptr;
    }

    auto *pointer = upstream_.allocate(size, alignment);
    if (pointer == nullptr) {
      release(size);
    }
    return pointer;
  }

  void deallocate(void *pointer, std::size_t size, std::size_t alignment) noexcept {
    if (pointer != nullptr) {
      auto mapping = mappings_.take(pointer);
      if (mapping) {
        const auto bytes = mapping.bytes().size();
        mapping = {};
        release(bytes);
      }

      upstream_.deallocate(pointer, size, alignment);
      release(size);
    }
  }

  bool reserve(std::size_t bytes) noexcept {
    return budget_.reserve(used_, limit_, bytes);
  }

  void release(std::size_t bytes) noexcept {
    budget_.release(used_, bytes);
  }

  std::size_t used() const noexcept {
    return budget_.usedBy(used_);
  }

  bool adoptMapping(const void *placeholder, MappedRegion &pixels) noexcept {
    return mappings_.adopt(placeholder, pixels);
  }

  std::span<const std::uint8_t> imagePixels(std::span<const std::uint8_t> bytes) const noexcept {
    return mappings_.resolve(bytes);
  }

private:
  Upstream &upstream_;
  MediaBudget &budget_;
  std::size_t limit_;
  std::size_t used_ = 0;
  MappedImages mappings_;
};

}
