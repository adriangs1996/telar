module;
#include "foundation/core/memory.hpp"

export module telar.gui.foundation.core:primitives;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::gui::inline foundation::inline core {
  using telar::gui::Allocator;
  using telar::gui::AllocatorRef;
  using telar::gui::BudgetAllocator;
  using telar::gui::makeOwned;
  using telar::gui::Owned;
  using telar::gui::SynchronizedAllocator;
  using telar::gui::SystemAllocator;
}
