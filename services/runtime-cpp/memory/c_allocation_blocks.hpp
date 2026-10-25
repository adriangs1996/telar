#pragma once

#include "allocator.hpp"
#include <cstring>

namespace telar::runtime {

template <Allocator Memory>
class CAllocationBlocks {
public:
  explicit CAllocationBlocks(Memory &memory) noexcept : memory_(memory) {}

  void *allocate(std::size_t size) noexcept {
    if (size > std::numeric_limits<std::size_t>::max() - sizeof(Header)) {
      return nullptr;
    }
    auto *header = static_cast<Header *>(memory_.allocate(sizeof(Header) + size, alignof(Header)));
    if (header == nullptr) {
      return nullptr;
    }
    std::construct_at(header, Header{size});
    return header + 1;
  }

  void *allocateZeroed(std::size_t count, std::size_t size) noexcept {
    if (size != 0 && count > std::numeric_limits<std::size_t>::max() / size) {
      return nullptr;
    }
    auto *pointer = allocate(count * size);
    if (pointer != nullptr) {
      std::memset(pointer, 0, count * size);
    }
    return pointer;
  }

  void release(void *pointer) noexcept {
    if (pointer != nullptr) {
      auto *header = static_cast<Header *>(pointer) - 1;
      memory_.deallocate(header, sizeof(Header) + header->size, alignof(Header));
    }
  }

  void *resize(void *pointer, std::size_t size) noexcept {
    if (pointer == nullptr) {
      return allocate(size);
    }
    if (size == 0) {
      release(pointer);
      return nullptr;
    }

    auto *replacement = allocate(size);
    if (replacement != nullptr) {
      const auto *header = static_cast<const Header *>(pointer) - 1;
      std::memcpy(replacement, pointer, std::min(header->size, size));
      release(pointer);
    }
    return replacement;
  }

private:
  struct alignas(std::max_align_t) Header {
    std::size_t size;
  };

  Memory &memory_;
};

template <Allocator Memory>
CAllocationBlocks(Memory &memory) -> CAllocationBlocks<Memory>;

}
