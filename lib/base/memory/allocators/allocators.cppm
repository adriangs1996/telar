module;
#include "telar_base/memory/allocator.hpp"

export module telar.base.memory.allocators;

import std;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar {
  using telar::AllocationDeleter;
  using telar::AllocationPath;
  using telar::AllocationStatistics;
  using telar::AllocationTotals;
  using telar::Allocator;
  using telar::AllocatorRef;
  using telar::BudgetAllocator;
  using telar::ConcurrentAllocator;
  using telar::ConcurrentMemory;
  using telar::ErasingMemory;
  using telar::makeOwned;
  using telar::Memory;
  using telar::MemoryAdapter;
  using telar::MemoryInterface;
  using telar::Owned;
  using telar::SensitiveAllocator;
  using telar::String;
  using telar::SynchronizedAllocator;
  using telar::SystemAllocator;
  using telar::Vector;
}
#if TELAR_DIAGNOSTICS
export namespace telar {
  using telar::AllocationScope;
  using telar::current_allocation_path;
  using telar::terminal_allocation;
  using telar::TerminalAllocationScope;
}
#endif

// Interface: telar_base/memory/buffer_allocator.cppm
export {
  namespace telar {

    template <Allocator Upstream>
    class TBC_SHARED BufferAllocator {
    public:
      static constexpr bool thread_safe = false;

      inline explicit BufferAllocator(Upstream& upstream, std::span<std::byte> buffer) noexcept
          : upstream_(upstream),
            buffer_(buffer) {}

      BufferAllocator(const BufferAllocator&) = delete;
      BufferAllocator& operator=(const BufferAllocator&) = delete;

      inline void* allocate(std::size_t size, std::size_t alignment) noexcept {
        if (used_ == buffer_.size()) {
          return upstream_.allocate(size, alignment);
        }

        void* available = buffer_.data() + used_;
        auto remaining = buffer_.size() - used_;
        if (void* aligned = std::align(alignment, size, available, remaining)) {
          used_ = buffer_.size() - remaining + size;
          return aligned;
        }

        return upstream_.allocate(size, alignment);
      }

      inline void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept {
        const auto address = reinterpret_cast<std::uintptr_t>(pointer);
        const auto beginning = reinterpret_cast<std::uintptr_t>(buffer_.data());
        if (address >= beginning && address - beginning < buffer_.size()) {
          return;
        }

        upstream_.deallocate(pointer, size, alignment);
      }

    private:
      Upstream& upstream_;
      std::span<std::byte> buffer_;
      std::size_t used_ = 0;
    };

    template <Allocator Upstream>
    BufferAllocator(Upstream& upstream, std::span<std::byte> buffer) -> BufferAllocator<Upstream>;

  }
}
