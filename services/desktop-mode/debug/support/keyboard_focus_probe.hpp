#pragma once

#include <cstdint>
#include <string>

class QWindow;

namespace keyboard_focus_probe {
  // As the desktop runs: an accessory application, without a Dock icon.
  void becomeAccessory();
  // Whether AppKit has this process in front.
  bool active();
  // This process's application state as AppKit sees it, and its key window.
  std::string describe(QWindow &input);
} // namespace keyboard_focus_probe
