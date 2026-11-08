export module telar.runtime.tests.erasure_checking_allocator;

import std;
export import telar.runtime.tests.check;
export import telar.base.memory;

export {
class ErasureCheckingAllocator {
public:
  void *allocate(std::size_t size, std::size_t alignment) noexcept {
    return budget.allocate(size, alignment);
  }

  void deallocate(void *pointer, std::size_t size, std::size_t alignment) noexcept {
    check(std::ranges::all_of(std::span{static_cast<unsigned char *>(pointer), size}, [](unsigned char byte) { return byte == 0; }));
    budget.deallocate(pointer, size, alignment);
  }

  telar::SystemAllocator system;
  telar::BudgetAllocator<telar::SystemAllocator> budget{system, 2 * 1024 * 1024};
};
}
