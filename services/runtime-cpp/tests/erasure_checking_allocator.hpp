#pragma once

#include "check.hpp"
#include "telar_base/memory/allocator.hpp"
#include <span>

class ErasureCheckingAllocator {
public:
  void *allocate(std::size_t size, std::size_t alignment) noexcept {
    return budget.allocate(size, alignment);
  }

  void deallocate(void *pointer, std::size_t size, std::size_t alignment) noexcept {
    check(std::ranges::all_of(std::span{static_cast<unsigned char *>(pointer), size}, [](unsigned char byte) { return byte == 0; }));
    budget.deallocate(pointer, size, alignment);
  }

  telar::runtime::SystemAllocator system;
  telar::runtime::BudgetAllocator<telar::runtime::SystemAllocator> budget{system, 2 * 1024 * 1024};
};
