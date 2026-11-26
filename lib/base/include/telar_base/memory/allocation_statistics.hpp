#pragma once

#include "telar_base/diagnostics/config.hpp"
#include "telar_base/diagnostics/timing.hpp"
#include "telar_base/ds/values.hpp"
#include <array>
#include <utility>

namespace telar {

  enum class AllocationPath : std::uint8_t {
    interactive,
    media,
    observation,
    other,
  };

  struct AllocationTotals {
    std::uint64_t count = 0;
    std::uint64_t bytes = 0;

    void record(std::size_t size) noexcept {
      accumulate(count);
      accumulate(bytes, size);
    }
  };

  struct AllocationStatistics {
    std::uint64_t live_bytes = 0;
    std::uint64_t live_allocations = 0;
    AllocationTotals total;
    ds::Array<AllocationTotals, 4> paths{};
    AllocationTotals interactive_terminal;
  };

#if TELAR_DIAGNOSTICS
  // The allocation context of each thread, which the scopes below set.
  inline thread_local ds::Cell<AllocationPath> current_allocation_path{AllocationPath::other}; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables): a thread's own state, which the scopes below set
  inline thread_local ds::Cell<bool> terminal_allocation{false};                               // NOLINT(cppcoreguidelines-avoid-non-const-global-variables): a thread's own state, which the scopes below set

  class AllocationScope {
  public:
    explicit AllocationScope(AllocationPath path) noexcept
        : previous_(current_allocation_path.get()) {
      current_allocation_path.set(path);
    }

    ~AllocationScope() {
      current_allocation_path.set(previous_);
    }

    AllocationScope(const AllocationScope&) = delete;
    AllocationScope& operator=(const AllocationScope&) = delete;
    AllocationScope(AllocationScope&&) = delete;
    AllocationScope& operator=(AllocationScope&&) = delete;

  private:
    AllocationPath previous_;
  };

  class TerminalAllocationScope {
  public:
    TerminalAllocationScope() noexcept
        : previous_(terminal_allocation.get()) {
      terminal_allocation.set(true);
    }

    ~TerminalAllocationScope() {
      terminal_allocation.set(previous_);
    }

    TerminalAllocationScope(const TerminalAllocationScope&) = delete;
    TerminalAllocationScope& operator=(const TerminalAllocationScope&) = delete;
    TerminalAllocationScope(TerminalAllocationScope&&) = delete;
    TerminalAllocationScope& operator=(TerminalAllocationScope&&) = delete;

  private:
    bool previous_;
  };
#endif

}
