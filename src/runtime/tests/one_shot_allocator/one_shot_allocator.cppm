module;
#include <cstdlib>

export module telar.runtime.tests.one_shot_allocator;

import std;
export import telar.base.memory;

export {
namespace telar::control_test {

class OneShotAllocator {
public:
  static constexpr bool thread_safe = true;

  void failNext() noexcept { fail_next_.store(true, std::memory_order_relaxed); }
  std::size_t failures() const noexcept { return failures_.load(std::memory_order_relaxed); }
  std::size_t liveBytes() const noexcept { return live_.load(std::memory_order_relaxed); }

  void *allocate(std::size_t size, std::size_t alignment) noexcept {
    if (fail_next_.exchange(false, std::memory_order_relaxed)) {
      failures_.fetch_add(1, std::memory_order_relaxed);
      return nullptr;
    }

    auto *pointer = upstream_.allocate(size, alignment);
    if (pointer != nullptr) {
      live_.fetch_add(size, std::memory_order_relaxed);
    }
    return pointer;
  }

  void deallocate(void *pointer, std::size_t size, std::size_t alignment) noexcept {
    if (pointer != nullptr) {
      if (live_.fetch_sub(size, std::memory_order_relaxed) < size) {
        std::abort();
      }
      upstream_.deallocate(pointer, size, alignment);
    }
  }

private:
  telar::SystemAllocator upstream_;
  std::atomic<bool> fail_next_{false};
  std::atomic<std::size_t> failures_{0};
  std::atomic<std::size_t> live_{0};
};

}
}
