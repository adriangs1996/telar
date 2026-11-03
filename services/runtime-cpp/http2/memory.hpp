#pragma once

#include "telar_base/memory/c_allocation_blocks.hpp"
#include "telar_base/memory/erasing_allocator.hpp"
#include <nghttp2/nghttp2.h>

namespace telar::runtime {

template <Allocator Memory>
class Http2Memory {
  using Blocks = CAllocationBlocks<ErasingAllocator<Memory>>;

public:
  explicit Http2Memory(Memory &memory) noexcept : memory_(memory), blocks_(memory_), callbacks_{.mem_user_data = &blocks_, .malloc = &allocate, .free = &release, .calloc = &allocateZeroed, .realloc = &resize} {}
  Http2Memory(const Http2Memory &) = delete;
  Http2Memory &operator=(const Http2Memory &) = delete;
  auto callbacks() noexcept -> nghttp2_mem * { return &callbacks_; }

private:
  static void *allocate(std::size_t size, void *owner) noexcept { return static_cast<Blocks *>(owner)->allocate(size); }
  static void release(void *pointer, void *owner) noexcept { static_cast<Blocks *>(owner)->release(pointer); }
  static void *allocateZeroed(std::size_t count, std::size_t size, void *owner) noexcept { return static_cast<Blocks *>(owner)->allocateZeroed(count, size); }
  static void *resize(void *pointer, std::size_t size, void *owner) noexcept { return static_cast<Blocks *>(owner)->resize(pointer, size); }

  ErasingAllocator<Memory> memory_;
  Blocks blocks_;
  nghttp2_mem callbacks_;
};

}
