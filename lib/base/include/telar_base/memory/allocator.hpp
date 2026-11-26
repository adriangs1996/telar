#pragma once

#include "tbc/view.hpp"
#include "telar_base/ds/values.hpp"
#include "telar_base/memory/allocation_statistics.hpp"
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

    static void* allocate(std::size_t size, std::size_t alignment) noexcept {
      if (alignment <= alignof(std::max_align_t)) {
        return std::malloc(size); // NOLINT(cppcoreguidelines-no-malloc,cppcoreguidelines-owning-memory): the allocator every other one ends in
      }

      void* pointer = nullptr;

      return posix_memalign(&pointer, alignment, size) == 0 ? pointer : nullptr;
    }

    static void deallocate(void* pointer, std::size_t /*size*/, std::size_t /*alignment*/) noexcept {
      std::free(pointer); // NOLINT(cppcoreguidelines-no-malloc,cppcoreguidelines-owning-memory): the allocator every other one ends in
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

    [[nodiscard]] std::size_t liveBytes() const noexcept {
      return live_bytes_;
    }

    [[nodiscard]] std::size_t peakBytes() const noexcept {
      return peak_bytes_;
    }

    [[nodiscard]] std::size_t allocations() const noexcept {
      return allocations_;
    }

    [[nodiscard]] std::size_t failures() const noexcept {
      return failures_;
    }

#if TELAR_DIAGNOSTICS
    [[nodiscard]] AllocationStatistics statistics() const noexcept {
      auto result = statistics_;

      result.live_bytes = live_bytes_;
      return result;
    }
#endif

  private:
#if TELAR_DIAGNOSTICS
    void recordAllocation(std::size_t size) noexcept {
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
  class TBC_SHARED SynchronizedAllocator {
  public:
    static constexpr bool thread_safe = true;

    explicit SynchronizedAllocator(Upstream& upstream) noexcept
        : upstream_(upstream) {}

    void* allocate(std::size_t size, std::size_t alignment) noexcept {
      const std::scoped_lock lock{mutex_};

      return upstream_.allocate(size, alignment);
    }

    void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept {
      const std::scoped_lock lock{mutex_};

      upstream_.deallocate(pointer, size, alignment);
    }

    auto statistics() const noexcept
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

  // Memory and ConcurrentMemory are interfaces of pure virtual calls, defined only by their
  // implementations: neither has a member to define out of line.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wweak-vtables"

  // An allocator behind a virtual call, so a service compiles once rather than once per allocator.
  // allocate returns nullptr, instead of throwing, when it cannot satisfy the request.
  class TBC_SHARED Memory {
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
    [[nodiscard]] virtual ds::Option<AllocationStatistics> statistics() const noexcept {
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

    ConcurrentMemory(const ConcurrentMemory&) = delete;
    ConcurrentMemory& operator=(const ConcurrentMemory&) = delete;
    ConcurrentMemory(ConcurrentMemory&&) = delete;
    ConcurrentMemory& operator=(ConcurrentMemory&&) = delete;

  protected:
    ConcurrentMemory() noexcept = default;
    ~ConcurrentMemory() = default;
  };

#pragma clang diagnostic pop

  // A Memory that erases every block before releasing it, for secrets.
  class TBC_SHARED ErasingMemory : public Memory {
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
    // constexpr, so that a unit declaring an adapter instantiates the constructor, and with it the
    // overrides, rather than only the unit that emits the vtable.
    explicit constexpr MemoryAdapter(tbc::mut_a<Upstream> upstream) noexcept
        : upstream_(upstream) {}

    void* allocate(std::size_t size, std::size_t alignment) noexcept override {
      return upstream_.allocate(size, alignment);
    }

    void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept override {
      upstream_.deallocate(pointer, size, alignment);
    }

#if TELAR_DIAGNOSTICS
    [[nodiscard]] ds::Option<AllocationStatistics> statistics() const noexcept override {
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
  class TBC_SHARED AllocatorRef {
  public:
    using value_type = Value;
    using propagate_on_container_move_assignment = std::false_type;
    using is_always_equal = std::false_type;

    // A handle to the allocator, whose region the containers that use it carry.
    explicit AllocatorRef(tbc::mut_a<Memory> memory) noexcept
        : memory_(&memory) {}

    template <typename Other>
    AllocatorRef(const AllocatorRef<Other, Memory>& other) noexcept // NOLINT(cppcoreguidelines-explicit-constructor,misc-explicit-constructor): rebinding converts implicitly, as std::allocator's does
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

    [[nodiscard]] tbc::mut_a<Memory> memory() const noexcept {
      return *memory_;
    }

    template <typename Other>
    bool operator==(const AllocatorRef<Other, Memory>& other) const noexcept {
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
