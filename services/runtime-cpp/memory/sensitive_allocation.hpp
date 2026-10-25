#pragma once

#include "erasing_allocator.hpp"
#include <cstdint>
#include <span>
#include <utility>

namespace telar::runtime {

template <Allocator Memory>
class SensitiveAllocation {
public:
  explicit SensitiveAllocation(Memory &memory, std::size_t size) : memory_(&memory), size_(size) {
    if (size != 0) {
      storage_ = static_cast<std::uint8_t *>(memory.allocate(size, alignof(std::uint8_t)));
      if (storage_ == nullptr) {
        throw std::bad_alloc{};
      }
    }
  }

  ~SensitiveAllocation() { release(); }

  SensitiveAllocation(const SensitiveAllocation &) = delete;
  SensitiveAllocation &operator=(const SensitiveAllocation &) = delete;

  SensitiveAllocation(SensitiveAllocation &&other) noexcept
      : memory_(other.memory_), storage_(std::exchange(other.storage_, nullptr)), size_(std::exchange(other.size_, 0)) {}

  SensitiveAllocation &operator=(SensitiveAllocation &&other) noexcept {
    if (this != &other) {
      release();
      memory_ = other.memory_;
      storage_ = std::exchange(other.storage_, nullptr);
      size_ = std::exchange(other.size_, 0);
    }
    return *this;
  }

  std::span<std::uint8_t> bytes() noexcept { return {storage_, size_}; }
  std::span<const std::uint8_t> bytes() const noexcept { return {storage_, size_}; }

private:
  void release() noexcept {
    ErasingAllocator sensitive{*memory_};
    sensitive.deallocate(storage_, size_, alignof(std::uint8_t));
  }

  Memory *memory_;
  std::uint8_t *storage_ = nullptr;
  std::size_t size_;
};

template <Allocator Memory>
SensitiveAllocation(Memory &memory, std::size_t size) -> SensitiveAllocation<Memory>;

}
