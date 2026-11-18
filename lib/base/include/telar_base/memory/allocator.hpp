#pragma once

#include "tbc/view.hpp"
#include "telar_base/memory/allocation_statistics.hpp"
#include "telar_base/ds/values.hpp"
#include <concepts>
#include <cstddef>
#include <cstdlib>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <optional>
#include <string>
#include <type_traits>
#include <vector>

namespace telar {

  template <typename Memory>
  concept Allocator = requires(Memory& memory, void* pointer, std::size_t size, std::size_t alignment) {
    { memory.allocate(size, alignment) } noexcept -> std::same_as<void*>;
    { memory.deallocate(pointer, size, alignment) } noexcept -> std::same_as<void>;
  };

  class TBC_SHARED SystemAllocator {
  public:
    static constexpr bool thread_safe = true;

    void* allocate(std::size_t size, std::size_t alignment) noexcept {
      if (alignment <= alignof(std::max_align_t)) {
        return std::malloc(size);
      }

      void* pointer = nullptr;

      return posix_memalign(&pointer, alignment, size) == 0 ? pointer : nullptr;
    }

    void deallocate(void* pointer, std::size_t, std::size_t) noexcept {
      std::free(pointer);
    }
  };

  template <Allocator Upstream>
  class TBC_SHARED BudgetAllocator {
  public:
    static constexpr bool thread_safe = false;

    explicit BudgetAllocator(Upstream& upstream, std::size_t limit) noexcept
        : upstream_(upstream),
          limit_(limit) {}

    void* allocate(std::size_t size, std::size_t alignment) noexcept {
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

    void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept {
      if (pointer == nullptr) {
        return;
      }

      upstream_.deallocate(pointer, size, alignment);
      live_bytes_ -= size;
      TELAR_DIAGNOSTIC(--statistics_.live_allocations);
    }

    std::size_t liveBytes() const noexcept {
      return live_bytes_;
    }

    std::size_t peakBytes() const noexcept {
      return peak_bytes_;
    }

    std::size_t allocations() const noexcept {
      return allocations_;
    }

    std::size_t failures() const noexcept {
      return failures_;
    }

#if TELAR_DIAGNOSTICS
    AllocationStatistics statistics() const noexcept {
      auto result = statistics_;

      result.live_bytes = live_bytes_;
      return result;
    }
#endif

  private:
#if TELAR_DIAGNOSTICS
    void recordAllocation(std::size_t size) noexcept {
      ++statistics_.live_allocations;
      statistics_.total.record(size);
      statistics_.paths.atMut(static_cast<std::size_t>(current_allocation_path)).record(size);
      if (current_allocation_path == AllocationPath::interactive && terminal_allocation) {
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
  class TBC_SHARED SynchronizedAllocator {
  public:
    static constexpr bool thread_safe = true;

    explicit SynchronizedAllocator(Upstream& upstream) noexcept
        : upstream_(upstream) {}

    void* allocate(std::size_t size, std::size_t alignment) noexcept {
      const std::lock_guard lock{mutex_};

      return upstream_.allocate(size, alignment);
    }

    void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept {
      const std::lock_guard lock{mutex_};

      upstream_.deallocate(pointer, size, alignment);
    }

    auto statistics() const noexcept
      requires requires(const Upstream& upstream) { upstream.statistics(); }
    {
      const std::lock_guard lock{mutex_};

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

  // An allocator behind a virtual call, so a service compiles once rather than once per allocator.
  // allocate returns nullptr, instead of throwing, when it cannot satisfy the request.
  class TBC_SHARED Memory {
  public:
    static constexpr bool thread_safe = false;

    Memory(const Memory&) = delete;
    Memory& operator=(const Memory&) = delete;

    virtual void* allocate(std::size_t size, std::size_t alignment) noexcept = 0;
    virtual void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept = 0;

#if TELAR_DIAGNOSTICS
    // What the allocator underneath counts, for the runtime's memory samples; nothing if it does not count.
    virtual ds::Option<AllocationStatistics> statistics() const noexcept {
      return ds::none;
    }
#endif

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
    explicit MemoryAdapter(tbc::view<Upstream&, tbc::lt::a> upstream) noexcept
        : upstream_(upstream) {}

    void* allocate(std::size_t size, std::size_t alignment) noexcept override {
      return upstream_.allocate(size, alignment);
    }

    void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept override {
      upstream_.deallocate(pointer, size, alignment);
    }

#if TELAR_DIAGNOSTICS
    ds::Option<AllocationStatistics> statistics() const noexcept override {
      if constexpr (requires(const Upstream& upstream) { upstream.statistics(); }) {
        return upstream_.statistics();
      } else {
        return ds::none;
      }
    }
#endif

  private:
    tbc::view<Upstream&, tbc::lt::a> upstream_;
  };

  template <Allocator Upstream>
  MemoryAdapter(Upstream& upstream) -> MemoryAdapter<Upstream>;

  template <typename Value, Allocator Memory>
  class TBC_SHARED AllocatorRef {
  public:
    using value_type = Value;
    using propagate_on_container_move_assignment = std::false_type;
    using is_always_equal = std::false_type;

    // A handle to the allocator, whose region the containers that use it carry.
    explicit AllocatorRef(tbc::view<Memory&, tbc::lt::a> memory) noexcept
        : memory_(&memory) {}

    template <typename Other>
    AllocatorRef(const AllocatorRef<Other, Memory>& other) noexcept
        : memory_(&other.memory()) {}

    Value* allocate(std::size_t count) {
      if (count > std::numeric_limits<std::size_t>::max() / sizeof(Value)) {
        throw std::bad_array_new_length{};
      }

      auto* pointer = static_cast<Value*>(memory_->allocate(count * sizeof(Value), alignof(Value)));
      if (pointer == nullptr) {
        throw std::bad_alloc{};
      }

      return pointer;
    }

    void deallocate(Value* pointer, std::size_t count) noexcept {
      memory_->deallocate(pointer, count * sizeof(Value), alignof(Value));
    }

    tbc::view<Memory&, tbc::lt::a> memory() const noexcept {
      return *memory_;
    }

    template <typename Other>
    bool operator==(const AllocatorRef<Other, Memory>& other) const noexcept {
      return memory_ == &other.memory();
    }

  private:
    tbc::view<Memory*, tbc::lt::a> memory_;
  };

  template <typename Value, Allocator Memory>
  using Vector = std::vector<Value, AllocatorRef<Value, Memory>>;

  template <Allocator Memory>
  using String = std::basic_string<char, std::char_traits<char>, AllocatorRef<char, Memory>>;

  template <typename Value, Allocator Memory>
  class AllocationDeleter {
  public:
    explicit AllocationDeleter(Memory& memory) noexcept
        : memory_(&memory) {}

    void operator()(Value* value) const noexcept {
      if (value != nullptr) {
        std::destroy_at(value);
        memory_->deallocate(value, sizeof(Value), alignof(Value));
      }
    }

  private:
    Memory* memory_;
  };

  template <typename Value, Allocator Memory>
  using Owned = std::unique_ptr<Value, AllocationDeleter<Value, Memory>>;

  // The owner keeps what Value's constructor keeps of the arguments, and its allocator.
  template <typename Value, Allocator Memory, typename... Arguments>
  TBC_CONSTRUCTS Owned<Value, Memory> makeOwned(Memory& memory, Arguments&&... arguments) {
    AllocatorRef<Value, Memory> allocator{memory};
    Value* value = allocator.allocate(1);

    try {
      std::construct_at(value, std::forward<Arguments>(arguments)...);
    } catch (...) {
      allocator.deallocate(value, 1);
      throw;
    }

    return Owned<Value, Memory>{value, AllocationDeleter<Value, Memory>{memory}};
  }

  static_assert(Allocator<SystemAllocator>);
  static_assert(Allocator<BudgetAllocator<SystemAllocator>>);
  static_assert(Allocator<Memory>);
  static_assert(ConcurrentAllocator<ConcurrentMemory>);
  static_assert(SensitiveAllocator<ErasingMemory>);

}
