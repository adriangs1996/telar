#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "check.hpp"
#include "erasure_checking_allocator.hpp"
#include "telar_base/memory/allocator.hpp"
#include <cstddef>
#include <cstring>
#include <array>
#include <cstdint>
#include <span>



import telar.base.memory;

using namespace telar;

void testRecyclingAllocator() {
  ErasureCheckingAllocator upstream;
  {
    RecyclingAllocator memory{upstream};
    for (const auto alignment : {alignof(char), alignof(std::max_align_t), std::size_t{64}}) {
      for (const std::size_t size : {1, 15, 16, 17, 31, 32, 4095, 4096, 4097}) {
        auto *first = memory.allocate(size, alignment);
        check(first != nullptr && reinterpret_cast<std::uintptr_t>(first) % alignment == 0);
        std::memset(first, 0x5a, size);
        memory.deallocate(first, size, alignment);
        const auto allocations = upstream.budget.allocations();
        auto *second = memory.allocate(size, alignment);
        check(second != nullptr && reinterpret_cast<std::uintptr_t>(second) % alignment == 0);
        if (size <= 4096 && alignment <= alignof(std::max_align_t)) {
          check(second == first && upstream.budget.allocations() == allocations);
        }
        std::memset(second, 0x6b, size);
        memory.deallocate(second, size, alignment);
      }
    }

    std::array<void *, 200> blocks;
    for (auto &block : blocks) {
      block = memory.allocate(4096, alignof(std::max_align_t));
      check(block != nullptr);
      std::memset(block, 0x7c, 4096);
    }
    for (auto *block : blocks) {
      memory.deallocate(block, 4096, alignof(std::max_align_t));
    }
    check(memory.retainedBytes() <= decltype(memory)::maximum_retained_bytes);
    check(upstream.budget.liveBytes() == memory.retainedBytes());
    check(memory.allocate(4 * 1024 * 1024, alignof(std::max_align_t)) == nullptr);
  }
  check(upstream.budget.liveBytes() == 0);
}
