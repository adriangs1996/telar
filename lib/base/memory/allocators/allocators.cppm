module;
#include "telar_base/diagnostics/config.hpp"

export module telar.base.memory.allocators;

import std;
import telar.tbc;
import telar.base.diagnostics.timing;
import telar.base.ds.values;

export {
  namespace telar {

    enum class AllocationPath : std::uint8_t {
      interactive,
      media,
      observation,
      other,
    };

    struct AllocationTotals {
      std::uint64_t count = 0;
      std::uint64_t bytes = 0;

      constexpr void record(std::size_t size) noexcept {
        accumulate(count);
        accumulate(bytes, size);
      }
    };

    struct AllocationStatistics {
      std::uint64_t live_bytes = 0;
      std::uint64_t live_allocations = 0;
      AllocationTotals total;
      ds::Array<AllocationTotals, 4> paths{};
      AllocationTotals interactive_terminal;
    };

#if TELAR_DIAGNOSTICS
    // The allocation context of each thread, which the scopes below set.
    inline thread_local ds::Cell<AllocationPath> current_allocation_path{AllocationPath::other}; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables): a thread's own state, which the scopes below set
    inline thread_local ds::Cell<bool> terminal_allocation{false};                               // NOLINT(cppcoreguidelines-avoid-non-const-global-variables): a thread's own state, which the scopes below set

    class AllocationScope {
    public:
      explicit AllocationScope(AllocationPath path) noexcept;
      ~AllocationScope();

      AllocationScope(const AllocationScope&) = delete;
      AllocationScope& operator=(const AllocationScope&) = delete;
      AllocationScope(AllocationScope&&) = delete;
      AllocationScope& operator=(AllocationScope&&) = delete;

    private:
      AllocationPath previous_;
    };

    class TerminalAllocationScope {
    public:
      TerminalAllocationScope() noexcept;
      ~TerminalAllocationScope();

      TerminalAllocationScope(const TerminalAllocationScope&) = delete;
      TerminalAllocationScope& operator=(const TerminalAllocationScope&) = delete;
      TerminalAllocationScope(TerminalAllocationScope&&) = delete;
      TerminalAllocationScope& operator=(TerminalAllocationScope&&) = delete;

    private:
      bool previous_;
    };
#endif

    template <typename Memory>
    concept Allocator = requires(Memory& memory, void* pointer, std::size_t size, std::size_t alignment) {
      { memory.allocate(size, alignment) } noexcept -> std::same_as<void*>;
      { memory.deallocate(pointer, size, alignment) } noexcept -> std::same_as<void>;
    };

    class [[tbc::shared]] SystemAllocator {
    public:
      static constexpr bool thread_safe = true;

      static void* allocate(std::size_t size, std::size_t alignment) noexcept;
      static void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept;
    };

    template <Allocator Upstream>
    class [[tbc::shared]] [[tbc::generic]] BudgetAllocator {
    public:
      static constexpr bool thread_safe = false;

      inline explicit BudgetAllocator(Upstream& upstream, std::size_t limit) noexcept
          : upstream_(upstream),
            limit_(limit) {}

      inline void* allocate(std::size_t size, std::size_t alignment) noexcept {
        if (size > limit_ - live_bytes_) {
          ++failures_;
          return nullptr;
        }

        void* pointer = upstream_.allocate(size, alignment);
        if (pointer == nullptr) {
          ++failures_;
          return nullptr;
        }

        live_bytes_ += size;
        peak_bytes_ = live_bytes_ > peak_bytes_ ? live_bytes_ : peak_bytes_;
        ++allocations_;
        TELAR_DIAGNOSTIC(recordAllocation(size));
        return pointer;
      }

      inline void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept {
        if (pointer == nullptr) {
          return;
        }

        upstream_.deallocate(pointer, size, alignment);
        live_bytes_ -= size;
        TELAR_DIAGNOSTIC(--statistics_.live_allocations);
      }

      [[nodiscard]] inline std::size_t liveBytes() const noexcept {
        return live_bytes_;
      }

      [[nodiscard]] inline std::size_t peakBytes() const noexcept {
        return peak_bytes_;
      }

      [[nodiscard]] inline std::size_t allocations() const noexcept {
        return allocations_;
      }

      [[nodiscard]] inline std::size_t failures() const noexcept {
        return failures_;
      }

#if TELAR_DIAGNOSTICS
      [[nodiscard]] inline AllocationStatistics statistics() const noexcept {
        auto result = statistics_;

        result.live_bytes = live_bytes_;
        return result;
      }
#endif

    private:
#if TELAR_DIAGNOSTICS
      inline void recordAllocation(std::size_t size) noexcept {
        const auto path = current_allocation_path.get();

        ++statistics_.live_allocations;
        statistics_.total.record(size);
        statistics_.paths.atMut(static_cast<std::size_t>(path)).record(size);
        if (path == AllocationPath::interactive && terminal_allocation.get()) {
          statistics_.interactive_terminal.record(size);
        }
      }

      AllocationStatistics statistics_;
#endif
      Upstream& upstream_;
      std::size_t limit_;
      std::size_t live_bytes_ = 0;
      std::size_t peak_bytes_ = 0;
      std::size_t allocations_ = 0;
      std::size_t failures_ = 0;
    };

    template <Allocator Upstream>
    BudgetAllocator(Upstream& upstream, std::size_t limit) -> BudgetAllocator<Upstream>;

    template <Allocator Upstream>
    class [[tbc::shared]] [[tbc::generic]] SynchronizedAllocator {
    public:
      static constexpr bool thread_safe = true;

      inline explicit SynchronizedAllocator(Upstream& upstream) noexcept
          : upstream_(upstream) {}

      inline void* allocate(std::size_t size, std::size_t alignment) noexcept {
        const std::scoped_lock lock{mutex_};

        return upstream_.allocate(size, alignment);
      }

      inline void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept {
        const std::scoped_lock lock{mutex_};

        upstream_.deallocate(pointer, size, alignment);
      }

      inline auto statistics() const noexcept
        requires requires(const Upstream& upstream) { upstream.statistics(); }
      {
        const std::scoped_lock lock{mutex_};

        return upstream_.statistics();
      }

    private:
      Upstream& upstream_;
      mutable std::mutex mutex_;
    };

    template <Allocator Upstream>
    SynchronizedAllocator(Upstream& upstream) -> SynchronizedAllocator<Upstream>;

    template <typename Memory>
    concept ConcurrentAllocator = Allocator<Memory> && Memory::thread_safe;

    // Memory and its refined interfaces are abstract allocator bases.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wweak-vtables"

    // An allocator behind a virtual call, so a service compiles once rather than once per allocator.
    // allocate returns nullptr, instead of throwing, when it cannot satisfy the request.
    class [[tbc::shared]] Memory {
    public:
      static constexpr bool thread_safe = false;

      Memory(const Memory&) = delete;
      Memory& operator=(const Memory&) = delete;
      Memory(Memory&&) = delete;
      Memory& operator=(Memory&&) = delete;

      virtual void* allocate(std::size_t size, std::size_t alignment) noexcept = 0;
      virtual void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept = 0;

#if TELAR_DIAGNOSTICS
      // What the allocator underneath counts, for the runtime's memory samples; nothing if it does not count.
      [[nodiscard]] virtual ds::Option<AllocationStatistics> statistics() const noexcept;
#endif

    protected:
      Memory() noexcept = default;
      ~Memory() = default;
    };

    // A Memory that any number of threads may call at once.
    class [[tbc::shared]] ConcurrentMemory : public Memory {
    public:
      static constexpr bool thread_safe = true;

      ConcurrentMemory(const ConcurrentMemory&) = delete;
      ConcurrentMemory& operator=(const ConcurrentMemory&) = delete;
      ConcurrentMemory(ConcurrentMemory&&) = delete;
      ConcurrentMemory& operator=(ConcurrentMemory&&) = delete;

    protected:
      ConcurrentMemory() noexcept = default;
      ~ConcurrentMemory() = default;
    };

    // A Memory that erases every block before releasing it, for secrets.
    class [[tbc::shared]] ErasingMemory : public Memory {
    public:
      static constexpr bool erasing = true;

      ErasingMemory(const ErasingMemory&) = delete;
      ErasingMemory& operator=(const ErasingMemory&) = delete;
      ErasingMemory(ErasingMemory&&) = delete;
      ErasingMemory& operator=(ErasingMemory&&) = delete;

    protected:
      ErasingMemory() noexcept = default;
      ~ErasingMemory() = default;
    };

#pragma clang diagnostic pop

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
    class [[tbc::shared]] [[tbc::generic]] MemoryAdapter final : public MemoryInterface<Upstream> {
    public:
      // constexpr, so that a unit declaring an adapter instantiates the constructor, and with it the
      // overrides, rather than only the unit that emits the vtable.
      explicit constexpr MemoryAdapter(tbc::mut_a<Upstream> upstream) noexcept
          : upstream_(upstream) {}

      inline void* allocate(std::size_t size, std::size_t alignment) noexcept override {
        return upstream_.allocate(size, alignment);
      }

      inline void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept override {
        upstream_.deallocate(pointer, size, alignment);
      }

#if TELAR_DIAGNOSTICS
      [[nodiscard]] inline ds::Option<AllocationStatistics> statistics() const noexcept override {
        if constexpr (requires(const Upstream& upstream) { upstream.statistics(); }) {
          return upstream_.statistics();
        } else {
          return ds::none;
        }
      }
#endif

    private:
      tbc::mut_a<Upstream> upstream_;
    };

    template <Allocator Upstream>
    MemoryAdapter(Upstream& upstream) -> MemoryAdapter<Upstream>;

    template <typename Value, Allocator Memory>
    class [[tbc::shared]] [[tbc::generic]] AllocatorRef {
    public:
      using value_type = Value;
      using propagate_on_container_move_assignment = std::false_type;
      using is_always_equal = std::false_type;

      // A handle to the allocator, whose region the containers that use it carry.
      inline explicit AllocatorRef(tbc::mut_a<Memory> memory) noexcept
          : memory_(&memory) {}

      template <typename Other>
      inline AllocatorRef(const AllocatorRef<Other, Memory>& other) noexcept // NOLINT(cppcoreguidelines-explicit-constructor,misc-explicit-constructor): rebinding converts implicitly, as std::allocator's does
          : memory_(&other.memory()) {}

      inline Value* allocate(std::size_t count) {
        if (count > std::numeric_limits<std::size_t>::max() / sizeof(Value)) {
          throw std::bad_array_new_length{};
        }

        auto* pointer = static_cast<Value*>(memory_->allocate(count * sizeof(Value), alignof(Value)));
        if (pointer == nullptr) {
          throw std::bad_alloc{};
        }

        return pointer;
      }

      inline void deallocate(Value* pointer, std::size_t count) noexcept {
        memory_->deallocate(pointer, count * sizeof(Value), alignof(Value));
      }

      [[nodiscard]] inline tbc::mut_a<Memory> memory() const noexcept {
        return *memory_;
      }

      template <typename Other>
      inline bool operator==(const AllocatorRef<Other, Memory>& other) const noexcept {
        return memory_ == &other.memory();
      }

    private:
      tbc::val_a<Memory*> memory_;
    };

    static_assert(Allocator<SystemAllocator>);
    static_assert(Allocator<BudgetAllocator<SystemAllocator>>);
    static_assert(Allocator<Memory>);
    static_assert(ConcurrentAllocator<ConcurrentMemory>);
    static_assert(SensitiveAllocator<ErasingMemory>);

  }
}

// Interface: telar_base/memory/buffer_allocator.cppm
export {
  namespace telar {

    // An allocator combinator on every allocation path, over any composed upstream.
    template <Allocator Upstream>
    class [[tbc::shared]] [[tbc::generic]] BufferAllocator {
    public:
      static constexpr bool thread_safe = false;

      inline explicit BufferAllocator(Upstream& upstream, std::span<std::byte> buffer) noexcept
          : upstream_(upstream),
            buffer_(buffer) {}

      BufferAllocator(const BufferAllocator&) = delete;
      BufferAllocator& operator=(const BufferAllocator&) = delete;
      BufferAllocator(BufferAllocator&&) = delete;
      BufferAllocator& operator=(BufferAllocator&&) = delete;
      ~BufferAllocator() = default;

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
        const auto address = std::bit_cast<std::uintptr_t>(pointer);
        const auto beginning = std::bit_cast<std::uintptr_t>(buffer_.data());
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
