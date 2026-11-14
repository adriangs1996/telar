#include "telar_ghostty/vt.hpp"
#include <cstdio>

import telar.ghostty.vt;

namespace {

  // GHOSTTY_MODE_* expands here to the header's ghostty_mode_new, which telar.ghostty.vt replaces
  // to keep its constants constexpr; a change to the packing shows up as a mismatch.
  int compare(const char* name, GhosttyMode exported, GhosttyMode library) {
    if (exported == library) {
      return 0;
    }

    std::fprintf(stderr, "%s: telar.ghostty.vt exports 0x%04x, libghostty-vt packs 0x%04x\n", name, static_cast<unsigned>(exported), static_cast<unsigned>(library));
    return 1;
  }

}

int main() {
  int failures = 0;

#define TELAR_COMPARE_MODE(name)                                        \
  {                                                                     \
    constexpr GhosttyMode exported = telar::ghostty::captured::name##_; \
    failures += compare(#name, exported, name);                         \
  }
  TELAR_GHOSTTY_MODES(TELAR_COMPARE_MODE)
#undef TELAR_COMPARE_MODE

  return failures == 0 ? 0 : 1;
}
