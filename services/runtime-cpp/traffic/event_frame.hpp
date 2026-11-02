#pragma once

#include "../memory/sensitive_allocation.hpp"
#include <memory>

namespace telar::runtime::traffic {

template <Allocator Memory>
struct EventFrame {
  explicit EventFrame(Memory &memory, std::size_t size) : bytes(memory, size) {}
  SensitiveAllocation<Memory> bytes;
};

}
