module;
#include "telar_base/diagnostics/config.hpp"

module telar.base.memory.allocators;

import std;
import telar.sys.posix;

namespace telar {

#if TELAR_DIAGNOSTICS
  AllocationScope::AllocationScope(AllocationPath path) noexcept
      : previous_(current_allocation_path.get()) {
    current_allocation_path.set(path);
  }

  AllocationScope::~AllocationScope() {
    current_allocation_path.set(previous_);
  }

  TerminalAllocationScope::TerminalAllocationScope() noexcept
      : previous_(terminal_allocation.get()) {
    terminal_allocation.set(true);
  }

  TerminalAllocationScope::~TerminalAllocationScope() {
    terminal_allocation.set(previous_);
  }
#endif

  void* SystemAllocator::allocate(std::size_t size, std::size_t alignment) noexcept {
    if (alignment <= alignof(std::max_align_t)) {
      return std::malloc(size); // NOLINT(cppcoreguidelines-no-malloc,cppcoreguidelines-owning-memory): the allocator every other one ends in
    }

    void* pointer = nullptr;

    return ::posix_memalign(&pointer, alignment, size) == 0 ? pointer : nullptr;
  }

  void SystemAllocator::deallocate(void* pointer, std::size_t /*size*/, std::size_t /*alignment*/) noexcept {
    std::free(pointer); // NOLINT(cppcoreguidelines-no-malloc,cppcoreguidelines-owning-memory): the allocator every other one ends in
  }

#if TELAR_DIAGNOSTICS
  ds::Option<AllocationStatistics> Memory::statistics() const noexcept {
    return ds::none;
  }
#endif

}
