export module telar.gui.foundation.core:primitives;

import telar.base.memory.allocators;

#ifndef TELAR_GUI_ALLOCATOR
#define TELAR_GUI_ALLOCATOR ::telar::SystemAllocator
#endif

export namespace telar::gui::inline foundation::inline core {
  using ::telar::Allocator;
  using ::telar::AllocatorRef;
  using ::telar::BudgetAllocator;
  using ::telar::MemoryAdapter;
  using ::telar::MemoryInterface;
  using ::telar::SynchronizedAllocator;
  using ::telar::SystemAllocator;

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

    [[tbc::hot_path]] [[nodiscard]] inline ApplicationAllocator& memory() noexcept {
      return adapter_;
    }

  private:
    ApplicationUpstream upstream_;
    MemoryAdapter<ApplicationUpstream> adapter_{upstream_};
  };
}
