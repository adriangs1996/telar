// The allocators behind the Memory that memory_call_probe.cpp measures. They live in their own
// translation unit, so the probe's loops see only Memory& and only link-time optimization can
// learn which allocator answers.
#include <cstddef>
#include <limits>

import telar.base.memory.allocators;

namespace telar::probe {

  Memory& memoryCallSource(int implementation) noexcept;

}

namespace {

  telar::SystemAllocator system_allocator;
  telar::MemoryAdapter system_memory{system_allocator};
#if MEMORY_CALL_IMPLEMENTATIONS > 1
  // Several implementations of Memory, as a binary with more than one composition root has, so
  // whole-program devirtualization cannot pick a single target.
  telar::BudgetAllocator budget_allocator{system_allocator, std::numeric_limits<std::size_t>::max()};
  telar::MemoryAdapter budget_memory{budget_allocator};
  telar::SynchronizedAllocator synchronized_allocator{budget_allocator};
  telar::MemoryAdapter synchronized_memory{synchronized_allocator};
#endif

}

namespace telar::probe {

  Memory& memoryCallSource(int implementation) noexcept {
#if MEMORY_CALL_IMPLEMENTATIONS > 1
    switch (implementation) {
    case 1:
      return budget_memory;
    case 2:
      return synchronized_memory;
    default:
      break;
    }
#endif

    static_cast<void>(implementation);
    return system_memory;
  }

}
