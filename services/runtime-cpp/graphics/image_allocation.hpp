#pragma once

#include "media_budget.hpp"
#include <utility>

namespace telar::runtime {

template <Allocator Memory>
class ImageAllocation {
public:
  explicit ImageAllocation(MediaAllocator<Memory> &memory, std::size_t byte_count) noexcept
      : memory_(memory) {
    placeholder_ = static_cast<std::uint8_t *>(memory_.allocate(placeholder_bytes, alignof(std::uint8_t)));
    if (placeholder_ == nullptr) {
      return;
    }
    if (!memory_.reserve(byte_count)) {
      memory_.deallocate(std::exchange(placeholder_, nullptr), placeholder_bytes, alignof(std::uint8_t));
      return;
    }
    reserved_bytes_ = byte_count;
  }

  ~ImageAllocation() {
    reset();
  }

  void reset() noexcept {
    if (reserved_bytes_ != 0) {
      memory_.release(std::exchange(reserved_bytes_, 0));
    }
    memory_.deallocate(std::exchange(placeholder_, nullptr), placeholder_bytes, alignof(std::uint8_t));
  }

  ImageAllocation(const ImageAllocation &) = delete;
  ImageAllocation &operator=(const ImageAllocation &) = delete;

  explicit operator bool() const noexcept {
    return placeholder_ != nullptr;
  }

  bool adopt(MappedRegion &mapping) noexcept {
    if (placeholder_ == nullptr || mapping.bytes().size() != reserved_bytes_ || !memory_.adoptMapping(placeholder_, mapping)) {
      return false;
    }

    reserved_bytes_ = 0;
    return true;
  }

  std::span<const std::uint8_t> placeholder() const noexcept {
    return {placeholder_, placeholder_bytes};
  }

  void release() noexcept {
    placeholder_ = nullptr;
  }

private:
  static constexpr std::size_t placeholder_bytes = 1;
  MediaAllocator<Memory> &memory_;
  std::uint8_t *placeholder_ = nullptr;
  std::size_t reserved_bytes_ = 0;
};

}
