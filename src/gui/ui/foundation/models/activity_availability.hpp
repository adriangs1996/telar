#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#pragma once

import telar.gui.machines.picker;

namespace telar::gui::qt {

  class Store;

  // Whether the target is still there to select: its machine connected and shown, and its
  // agent, process or worktree still listed.
  [[nodiscard]] bool activityAvailable(const Store& store, const MachineActivityTarget& target);

}
