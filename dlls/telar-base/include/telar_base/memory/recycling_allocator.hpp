#pragma once

#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/erase_sensitive.hpp"
#include <array>

namespace telar::runtime {

template <Allocator Upstream>
class RecyclingAllocator {
public:
  static constexpr bool thread_safe = false;

  explicit RecyclingAllocator(Upstream &upstream) noexcept : upstream_(upstream) {}

  ~RecyclingAllocator() {
    for (std::size_t index = 0; index < available_.size(); ++index) {
      const auto capacity = (index + 1) * block_alignment;
      while (auto *block = available_[index]) {
        available_[index] = block->next;
        eraseSensitive(block, capacity);
        upstream_.deallocate(block, capacity, block_alignment);
      }
    }
  }

  RecyclingAllocator(const RecyclingAllocator &) = delete;
  RecyclingAllocator &operator=(const RecyclingAllocator &) = delete;

  void *allocate(std::size_t size, std::size_t alignment) noexcept {
    if (!recyclable(size, alignment)) {
      return upstream_.allocate(size, alignment);
    }

    const auto index = bucket(size);
    const auto capacity = (index + 1) * block_alignment;
    if (auto *block = available_[index]) {
      available_[index] = block->next;
      retained_bytes_ -= capacity;
      return block;
    }
    return upstream_.allocate(capacity, block_alignment);
  }

  void deallocate(void *pointer, std::size_t size, std::size_t alignment) noexcept {
    if (pointer == nullptr) {
      return;
    }
    if (!recyclable(size, alignment)) {
      eraseSensitive(pointer, size);
      upstream_.deallocate(pointer, size, alignment);
      return;
    }

    const auto index = bucket(size);
    const auto capacity = (index + 1) * block_alignment;
    eraseSensitive(pointer, capacity);
    if (capacity > maximum_retained_bytes - retained_bytes_) {
      upstream_.deallocate(pointer, capacity, block_alignment);
      return;
    }

    available_[index] = std::construct_at(static_cast<Block *>(pointer), Block{available_[index]});
    retained_bytes_ += capacity;
  }

  std::size_t retainedBytes() const noexcept { return retained_bytes_; }

  static constexpr std::size_t maximum_retained_bytes = 512 * 1024;

private:
  struct Block {
    Block *next;
  };

  static bool recyclable(std::size_t size, std::size_t alignment) noexcept {
    return size != 0 && size <= maximum_block_bytes && alignment <= block_alignment;
  }

  static std::size_t bucket(std::size_t size) noexcept {
    return (size - 1) / block_alignment;
  }

  static constexpr std::size_t block_alignment = alignof(std::max_align_t);
  static constexpr std::size_t maximum_block_bytes = 4096;
  Upstream &upstream_;
  std::array<Block *, maximum_block_bytes / block_alignment> available_{};
  std::size_t retained_bytes_ = 0;
};

}
