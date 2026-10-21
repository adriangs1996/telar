#pragma once

#include "desktop_state.hpp"

namespace macos::spaces {
  DesktopState snapshot();
  std::uint64_t create();
  void remove(std::uint64_t space);
  void activate(const DesktopState &state, std::uint64_t space);
  void move(std::uint64_t space, const DesktopDisplay &display, unsigned index);
  void focusDisplay(const DesktopDisplay &display);
  void moveWindow(std::uint32_t window, std::uint64_t space);
} // namespace macos::spaces
