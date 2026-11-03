#pragma once

#include "telar_base/diagnostics/config.hpp"
#include "telar_base/diagnostics/timing.hpp"
#include <array>
#include <utility>

namespace telar::runtime {

enum class AllocationPath {
  interactive,
  media,
  observation,
  other
};

struct AllocationTotals {
  std::uint64_t count = 0;
  std::uint64_t bytes = 0;

  void record(std::size_t size) noexcept {
    diagnostics::accumulate(count);
    diagnostics::accumulate(bytes, size);
  }
};

struct AllocationStatistics {
  std::uint64_t live_bytes = 0;
  std::uint64_t live_allocations = 0;
  AllocationTotals total;
  std::array<AllocationTotals, 4> paths{};
  AllocationTotals interactive_terminal;
};

#if TELAR_DIAGNOSTICS
inline thread_local AllocationPath current_allocation_path = AllocationPath::other;
inline thread_local bool terminal_allocation = false;

class AllocationScope {
public:
  explicit AllocationScope(AllocationPath path) noexcept
      : previous_(std::exchange(current_allocation_path, path)) {}

  ~AllocationScope() {
    current_allocation_path = previous_;
  }

  AllocationScope(const AllocationScope &) = delete;
  AllocationScope &operator=(const AllocationScope &) = delete;

private:
  AllocationPath previous_;
};

class TerminalAllocationScope {
public:
  TerminalAllocationScope() noexcept
      : previous_(std::exchange(terminal_allocation, true)) {}

  ~TerminalAllocationScope() {
    terminal_allocation = previous_;
  }

  TerminalAllocationScope(const TerminalAllocationScope &) = delete;
  TerminalAllocationScope &operator=(const TerminalAllocationScope &) = delete;

private:
  bool previous_;
};
#endif

}
