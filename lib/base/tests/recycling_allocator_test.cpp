#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstdint>
#include <cstring>

import std;
import telar.testing;
import telar.testing.erasure_checking_allocator;
import telar.base.memory.allocators;
import telar.base.memory.sensitive;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;

  void testRecyclingAllocator() {
    ErasureCheckingAllocator upstream;
    MemoryAdapter erased{upstream};

    {
      RecyclingAllocator<Memory> memory{erased};

      for (const auto alignment : {alignof(char), alignof(std::max_align_t), std::size_t{64}}) {
        for (const std::size_t size : {1, 15, 16, 17, 31, 32, 4095, 4096, 4097}) {
          auto* first = memory.allocate(size, alignment);

          check(first != nullptr && reinterpret_cast<std::uintptr_t>(first) % alignment == 0);
          std::memset(first, 0x5a, size);
          memory.deallocate(first, size, alignment);
          const auto allocations = upstream.budget.allocations();
          auto* second = memory.allocate(size, alignment);

          check(second != nullptr && reinterpret_cast<std::uintptr_t>(second) % alignment == 0);
          if (size <= 4096 && alignment <= alignof(std::max_align_t)) {
            check(second == first && upstream.budget.allocations() == allocations);
          }

          std::memset(second, 0x6b, size);
          memory.deallocate(second, size, alignment);
        }
      }

      ds::Array<void*, 200> blocks;

      for (auto& block : blocks.viewMut()) {
        block = memory.allocate(4096, alignof(std::max_align_t));
        check(block != nullptr);
        std::memset(block, 0x7c, 4096);
      }

      for (auto* block : blocks) {
        memory.deallocate(block, 4096, alignof(std::max_align_t));
      }

      check(memory.retainedBytes() <= decltype(memory)::maximum_retained_bytes);
      check(upstream.budget.liveBytes() == memory.retainedBytes());
      check(memory.allocate(4 * 1024 * 1024, alignof(std::max_align_t)) == nullptr);
    }

    check(upstream.budget.liveBytes() == 0);
  }

  const telar::testing::Case case_recycling_allocator{"recycling_allocator.recycling_allocator", testRecyclingAllocator};

}
