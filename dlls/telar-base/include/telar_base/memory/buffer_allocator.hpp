#pragma once

#include "telar_base/memory/allocator.hpp"
#include <cstdint>
#include <span>

namespace telar {

template <Allocator Upstream>
class BufferAllocator {
public:
  static constexpr bool thread_safe = false;

  explicit BufferAllocator(Upstream &upstream, std::span<std::byte> buffer) noexcept
      : upstream_(upstream), buffer_(buffer) {}

  BufferAllocator(const BufferAllocator &) = delete;
  BufferAllocator &operator=(const BufferAllocator &) = delete;

  void *allocate(std::size_t size, std::size_t alignment) noexcept {
    if (used_ == buffer_.size()) {
      return upstream_.allocate(size, alignment);
    }

    void *available = buffer_.data() + used_;
    auto remaining = buffer_.size() - used_;
    if (void *aligned = std::align(alignment, size, available, remaining)) {
      used_ = buffer_.size() - remaining + size;
      return aligned;
    }

    return upstream_.allocate(size, alignment);
  }

  void deallocate(void *pointer, std::size_t size, std::size_t alignment) noexcept {
    const auto address = reinterpret_cast<std::uintptr_t>(pointer);
    const auto beginning = reinterpret_cast<std::uintptr_t>(buffer_.data());
    if (address >= beginning && address - beginning < buffer_.size()) {
      return;
    }

    upstream_.deallocate(pointer, size, alignment);
  }

private:
  Upstream &upstream_;
  std::span<std::byte> buffer_;
  std::size_t used_ = 0;
};

template <Allocator Upstream>
BufferAllocator(Upstream &upstream, std::span<std::byte> buffer) -> BufferAllocator<Upstream>;

}
