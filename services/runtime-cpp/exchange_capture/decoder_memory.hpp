#pragma once

#include "telar_base/memory/c_allocation_blocks.hpp"
#include "telar_base/memory/erasing_allocator.hpp"

namespace telar::runtime {

template <Allocator Memory>
class DecoderMemory {
public:
  explicit DecoderMemory(Memory &memory) noexcept : memory_(memory), blocks_(memory_) {}

  static void *allocate(void *context, std::size_t bytes) noexcept {
    return static_cast<DecoderMemory *>(context)->blocks_.allocate(bytes);
  }

  static void *allocateArray(void *context, unsigned count, unsigned size) noexcept {
    if (size != 0 && count > std::numeric_limits<std::size_t>::max() / size) {
      return nullptr;
    }
    return allocate(context, static_cast<std::size_t>(count) * size);
  }

  static void release(void *context, void *pointer) noexcept {
    static_cast<DecoderMemory *>(context)->blocks_.release(pointer);
  }

private:
  ErasingAllocator<Memory> memory_;
  CAllocationBlocks<ErasingAllocator<Memory>> blocks_;
};

}
