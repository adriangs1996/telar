#pragma once

#include "desktop_state.hpp"

namespace macos::spaces {
  DesktopState snapshot();
  std::uint64_t create();
  void remove(std::uint64_t space);
  void activate(const DesktopState &state, std::uint64_t space);
  void move(std::uint64_t space, const DesktopDisplay &display, unsigned index);
  void focusDisplay(const DesktopDisplay &display);
} // namespace macos::spaces
