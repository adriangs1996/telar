#pragma once

#include <cstdint>

class QWindow;

namespace layers_probe {
  std::uint32_t windowNumber(QWindow &window);
  // Puts the window at the level of Telar's wallpaper: above macOS's, below every other window.
  void setWallpaperLevel(QWindow &window);
} // namespace layers_probe
