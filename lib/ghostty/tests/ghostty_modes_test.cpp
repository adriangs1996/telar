#include "telar_ghostty/modes.hpp"
#include <cstdio>

import telar.ghostty.vt;
import telar.testing;

namespace {

  // GHOSTTY_MODE_* expands here to the header's ghostty_mode_new, which telar.ghostty.vt replaces
  // to keep its constants constexpr; a change to the packing shows up as a mismatch.
  void compare(const char* name, GhosttyMode exported, GhosttyMode library) {
    if (exported != library) {
      std::fprintf(stderr, "%s: telar.ghostty.vt exports 0x%04x, libghostty-vt packs 0x%04x\n", name, static_cast<unsigned>(exported), static_cast<unsigned>(library));
    }

    telar::testing::expect(exported == library, name);
  }

}

static void modes() {
#define TELAR_COMPARE_MODE(name)                                        \
  {                                                                     \
    constexpr GhosttyMode exported = telar::ghostty::captured::name##_; \
    compare(#name, exported, name);                                     \
  }
  TELAR_GHOSTTY_MODES(TELAR_COMPARE_MODE)
#undef TELAR_COMPARE_MODE
}

static const telar::testing::Case case_modes{"ghostty_modes.modes", modes};
