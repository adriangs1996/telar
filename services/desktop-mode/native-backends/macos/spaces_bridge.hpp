#pragma once

#include "desktop_state.hpp"
#include <cstdint>
#include <span>
#include <vector>

namespace macos::spaces {
  DesktopState snapshot();
  void focusDisplay(const DesktopDisplay &display);
  // The first Space the window server lists for a window, layers included; 0 when none.
  std::uint64_t spaceOf(std::uint32_t window);

  // Layers are unmanaged Spaces: Mission Control does not know them, they hold windows of any
  // application, and the window server shows or hides each one whole, above the desktop's windows
  // at a level of 1 or more and below all of them at a negative level.
  //
  // Creates a layer at a level, stamped as this process's. A round trip to WindowManager that can
  // take longer than a frame: never on the UI thread.
  std::uint64_t createLayer(int level);
  void destroyLayer(std::uint64_t layer);
  // Moves windows of any application into a layer, out of every Space they were in.
  void moveToLayer(std::span<const std::uint32_t> windows, std::uint64_t layer);
  void showLayers(std::span<const std::uint64_t> shown, std::span<const std::uint64_t> hidden);
  // Returns every other application's window in these layers to the desktop its display shows.
  void evacuate(std::span<const std::uint64_t> layers);
  // Layers stamped by a Telar process that is no longer running. Off the UI thread.
  std::vector<std::uint64_t> strayLayers();
} // namespace macos::spaces
