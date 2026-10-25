#pragma once

#include "../memory/allocator.hpp"
#include <ghostty/vt.h>

namespace telar::runtime {

template <Allocator Memory>
class GhosttyAllocatorBridge {
public:
  explicit GhosttyAllocatorBridge(Memory &memory) noexcept
      : allocator_{.ctx = &memory,
                   .vtable = &callbacks_} {}

  const GhosttyAllocator *get() const noexcept {
    return &allocator_;
  }

  Memory &memory() const noexcept {
    return *static_cast<Memory *>(allocator_.ctx);
  }

private:
  static void *allocate(void *context, std::size_t size, std::uint8_t alignment, std::uintptr_t) noexcept {
    TELAR_DIAGNOSTIC(TerminalAllocationScope allocation_scope);
    // The pinned ABI passes log2(alignment), despite allocator.h describing bytes.
    if (alignment >= std::numeric_limits<std::size_t>::digits) {
      return nullptr;
    }

    return static_cast<Memory *>(context)->allocate(size, std::size_t{1} << alignment);
  }

  static bool resize(void *, void *, std::size_t, std::uint8_t, std::size_t, std::uintptr_t) noexcept {
    return false;
  }

  static void *remap(void *, void *, std::size_t, std::uint8_t, std::size_t, std::uintptr_t) noexcept {
    return nullptr;
  }

  static void deallocate(void *context, void *pointer, std::size_t size, std::uint8_t alignment, std::uintptr_t) noexcept {
    static_cast<Memory *>(context)->deallocate(pointer, size, std::size_t{1} << alignment);
  }

  inline static constexpr GhosttyAllocatorVtable callbacks_{
      .alloc = allocate,
      .resize = resize,
      .remap = remap,
      .free = deallocate,
  };

  GhosttyAllocator allocator_;
};

}
