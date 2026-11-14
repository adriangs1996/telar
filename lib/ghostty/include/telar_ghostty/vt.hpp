#pragma once

// libghostty-vt's C API for the textual headers that cannot import telar.ghostty.vt, which owns
// this header; module units import that module instead.
#include <ghostty/vt.h>

// The modes the tree reads. telar.ghostty.vt exports each as a constant, and the runtime's
// ghostty-modes test checks every one against the header's own ghostty_mode_new.
#define TELAR_GHOSTTY_MODES(X)     \
  X(GHOSTTY_MODE_ALT_SCROLL)       \
  X(GHOSTTY_MODE_ANY_MOUSE)        \
  X(GHOSTTY_MODE_BRACKETED_PASTE)  \
  X(GHOSTTY_MODE_BUTTON_MOUSE)     \
  X(GHOSTTY_MODE_DECCKM)           \
  X(GHOSTTY_MODE_FOCUS_EVENT)      \
  X(GHOSTTY_MODE_KEYPAD_KEYS)      \
  X(GHOSTTY_MODE_NORMAL_MOUSE)     \
  X(GHOSTTY_MODE_REVERSE_COLORS)   \
  X(GHOSTTY_MODE_SGR_MOUSE)        \
  X(GHOSTTY_MODE_SGR_PIXELS_MOUSE) \
  X(GHOSTTY_MODE_SYNC_OUTPUT)      \
  X(GHOSTTY_MODE_X10_MOUSE)
