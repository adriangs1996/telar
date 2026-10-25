#pragma once

#include "../memory/sensitive_allocation.hpp"

namespace telar::runtime {

template <Allocator Memory>
struct DecodedBody {
  explicit DecodedBody(Memory &memory, std::size_t capacity) : storage(memory, capacity) {}

  std::span<const std::uint8_t> bytes() const noexcept { return storage.bytes().first(size); }

  SensitiveAllocation<Memory> storage;
  std::size_t size = 0;
  bool decoded = false;
  bool truncated = false;
  bool failed = false;
};

}
