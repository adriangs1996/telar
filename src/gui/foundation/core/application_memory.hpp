#pragma once

#include "foundation/core/memory.hpp"

#ifndef TELAR_GUI_ALLOCATOR
#define TELAR_GUI_ALLOCATOR ::telar::gui::SystemAllocator
#endif

namespace telar::gui {

  // The allocator TELAR_GUI_ALLOCATOR picks. Only ApplicationMemory names it.
  using ApplicationUpstream = TELAR_GUI_ALLOCATOR;
  static_assert(Allocator<ApplicationUpstream>);

  // What the GUI takes: ApplicationUpstream behind the strongest Memory interface it implements.
  using ApplicationAllocator = MemoryInterface<ApplicationUpstream>;

  // A GUI composition root: it owns the allocator and the MemoryAdapter that puts it behind
  // ApplicationAllocator. The adapter keeps the allocator's address, so the root never moves.
  class ApplicationMemory {
  public:
    ApplicationMemory() noexcept = default;
    ~ApplicationMemory() = default;
    ApplicationMemory(const ApplicationMemory&) = delete;
    ApplicationMemory& operator=(const ApplicationMemory&) = delete;
    ApplicationMemory(ApplicationMemory&&) = delete;
    ApplicationMemory& operator=(ApplicationMemory&&) = delete;

    [[nodiscard]] ApplicationAllocator& memory() noexcept {
      return adapter_;
    }

  private:
    ApplicationUpstream upstream_;
    MemoryAdapter<ApplicationUpstream> adapter_{upstream_};
  };

}
