module;
#include "telar_base/memory/allocator.hpp"
#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <type_traits>

export module telar.base.memory.allocators;

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
  using telar::makeOwned;
  using telar::Owned;
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

// Interface: the type-erased allocator a service takes at its boundary.
export {
  namespace telar {

    // An allocator behind a virtual call, so a service compiles once rather than once per allocator.
    // allocate returns nullptr, instead of throwing, when it cannot satisfy the request.
    class TBC_SHARED Memory {
    public:
      static constexpr bool thread_safe = false;

      Memory(const Memory&) = delete;
      Memory& operator=(const Memory&) = delete;

      virtual void* allocate(std::size_t size, std::size_t alignment) noexcept = 0;
      virtual void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept = 0;

    protected:
      Memory() noexcept = default;
      ~Memory() = default;
    };

    // A Memory that any number of threads may call at once.
    class TBC_SHARED ConcurrentMemory : public Memory {
    public:
      static constexpr bool thread_safe = true;

    protected:
      ConcurrentMemory() noexcept = default;
      ~ConcurrentMemory() = default;
    };

    // A Memory that erases every block before releasing it, for secrets.
    class TBC_SHARED ErasingMemory : public Memory {
    public:
      static constexpr bool erasing = true;

    protected:
      ErasingMemory() noexcept = default;
      ~ErasingMemory() = default;
    };

    // An allocator that erases every block it releases, as ErasingAllocator does.
    template <typename Upstream>
    concept SensitiveAllocator = Allocator<Upstream> && Upstream::erasing;

    // The strongest interface an allocator's guarantees let it implement. Erasing wins over
    // concurrency: a secret must not reach code that would release it without erasing it.
    template <Allocator Upstream>
    using MemoryInterface = std::conditional_t<
        SensitiveAllocator<Upstream>,
        ErasingMemory,
        std::conditional_t<ConcurrentAllocator<Upstream>, ConcurrentMemory, Memory>>;

    // Puts any allocator, test fakes included, behind Memory. It keeps the allocator by reference.
    template <Allocator Upstream>
    class TBC_SHARED MemoryAdapter final : public MemoryInterface<Upstream> {
    public:
      inline explicit MemoryAdapter(tbc::view<Upstream&, tbc::lt::a> upstream) noexcept
          : upstream_(upstream) {}

      inline void* allocate(std::size_t size, std::size_t alignment) noexcept override {
        return upstream_.allocate(size, alignment);
      }

      inline void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept override {
        upstream_.deallocate(pointer, size, alignment);
      }

    private:
      tbc::view<Upstream&, tbc::lt::a> upstream_;
    };

    template <Allocator Upstream>
    MemoryAdapter(Upstream& upstream) -> MemoryAdapter<Upstream>;

    static_assert(Allocator<Memory>);
    static_assert(ConcurrentAllocator<ConcurrentMemory>);
    static_assert(SensitiveAllocator<ErasingMemory>);

  }
}
