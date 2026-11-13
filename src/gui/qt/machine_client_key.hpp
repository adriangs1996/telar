#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstdint>

#pragma once


import telar.gui.machines.picker;

namespace telar::gui::qt {

struct MachineClientKey {
  MachineToken machine;
  std::uint64_t generation = 0;

  bool operator==(const MachineClientKey &) const noexcept = default;
};

}
