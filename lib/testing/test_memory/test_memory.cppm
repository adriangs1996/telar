export module telar.testing.test_memory;

import std;
import telar.testing;
import telar.base.memory.allocators;

export namespace telar::testing {

  // The memory a test hands what it checks, as Zig's testing allocator: it counts the bytes held
  // and fails the test when any is still held as it goes, so code that frees too little fails its
  // test instead of leaking unseen. Declared before what uses it, it outlives all of it. Any
  // number of threads may use it at once.
  class TestMemory final : public ConcurrentMemory {
  public:
    explicit TestMemory(std::source_location location = std::source_location::current()) noexcept
        : location_(location) {}

    TestMemory(const TestMemory&) = delete;
    TestMemory& operator=(const TestMemory&) = delete;
    TestMemory(TestMemory&&) = delete;
    TestMemory& operator=(TestMemory&&) = delete;

    ~TestMemory() {
      if (liveBytes() != 0) {
        fail("memory still held when the test's memory went", location_);
      }
    }

    void* allocate(std::size_t size, std::size_t alignment) noexcept override {
      void* pointer = system_.allocate(size, alignment);
      if (pointer != nullptr) {
        live_.fetch_add(size, std::memory_order_relaxed);
        allocations_.fetch_add(1, std::memory_order_relaxed);
      }

      return pointer;
    }

    void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept override {
      if (pointer == nullptr) {
        return;
      }

      if (live_.fetch_sub(size, std::memory_order_relaxed) < size) {
        fail("memory freed that the test's memory never gave", location_);
      }

      system_.deallocate(pointer, size, alignment);
    }

    // The bytes given and not yet freed.
    [[nodiscard]] std::size_t liveBytes() const noexcept {
      return live_.load(std::memory_order_relaxed);
    }

    // How many allocations it has made.
    [[nodiscard]] std::size_t allocations() const noexcept {
      return allocations_.load(std::memory_order_relaxed);
    }

  private:
    SystemAllocator system_;
    std::atomic<std::size_t> live_{0};
    std::atomic<std::size_t> allocations_{0};
    std::source_location location_;
  };

}
