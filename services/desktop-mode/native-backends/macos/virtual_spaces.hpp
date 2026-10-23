#pragma once

#include "desktop_state.hpp"
#include <CoreGraphics/CGGeometry.h>
#include <cstdint>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <vector>

namespace macos::spaces {
  // Telar's Spaces on macOS, made of layers instead of Mission Control's Spaces, as the Linux
  // compositor makes its own. Each one has a stage, the layer shown while its display shows the
  // Space, and a shelf that is never shown, where the windows of its hidden tabs wait. A Space is
  // known by its stage's identifier. Stages sit at level 0, where their windows interleave with
  // the desktop's by the usual ordering and window levels: above the wallpapers, below Telar's
  // bars and menus, and in front of or behind unmanaged applications as the user clicks.
  //
  // One per process: the UI thread, the Spaces observer and the window observer all use it.
  class VirtualSpaces final {
  public:
    static VirtualSpaces &get();

    // Off the UI thread: returns the windows of layers a Telar that is no longer running left
    // behind to their desktops.
    void prepare();
    // Off the UI thread. A display's first Space is shown at once.
    std::uint64_t create(std::uint32_t display);
    // Off the UI thread: returns other applications' windows to their desktop first.
    void remove(std::uint64_t space);
    // On stop: every other application's window back to its desktop, every layer destroyed.
    void release();

    // Shows the Space instead of the one its display showed, in one batched call.
    void show(std::uint64_t space);
    std::uint64_t stage(std::uint64_t space) const;
    std::uint64_t shelf(std::uint64_t space) const;
    std::uint32_t display(std::uint64_t space) const;
    // The Space a window is in, from the first Space the window server lists for it: its stage or
    // shelf gives the Space itself, and a desktop the Space shown on the display under `point`,
    // where an application's new window appears. Full-screen Spaces stay as they are.
    std::uint64_t resolve(std::uint64_t space, CGPoint point) const;
    // Replaces a snapshot's ordinary desktops with Telar's Spaces. Full-screen Spaces stay and,
    // while one is current on a display, that display shows no Telar Space.
    void overlay(DesktopState &state);

  private:
    struct Space {
      std::uint64_t stage = 0;
      std::uint64_t shelf = 0;
      std::uint32_t display = 0;
    };

    mutable std::mutex mutex_;
    // In creation order, which is their order on a display.
    std::vector<Space> spaces_;
    std::map<std::uint32_t, std::uint64_t> shown_;
    std::vector<DesktopDisplay> displays_;
    std::set<std::uint64_t> fullscreen_;

    VirtualSpaces() = default;
    // A copy, so nothing outlives the lock it was read under.
    std::optional<Space> find(std::uint64_t space) const;
  };
} // namespace macos::spaces
