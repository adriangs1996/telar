#pragma once

#include "allocator.hpp"
#include "erase_sensitive.hpp"

namespace telar::runtime {

template <Allocator Upstream>
class ErasingAllocator {
public:
  static constexpr bool thread_safe = ConcurrentAllocator<Upstream>;

  explicit ErasingAllocator(Upstream &upstream) noexcept
      : upstream_(upstream) {}

  void *allocate(std::size_t size, std::size_t alignment) noexcept {
    return upstream_.allocate(size, alignment);
  }

  void deallocate(void *pointer, std::size_t size, std::size_t alignment) noexcept {
    if (pointer != nullptr) {
      eraseSensitive(pointer, size);
      upstream_.deallocate(pointer, size, alignment);
    }
  }

private:
  Upstream &upstream_;
};

}
