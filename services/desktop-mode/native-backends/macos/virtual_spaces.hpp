#pragma once

#include "desktop_state.hpp"
#include <CoreGraphics/CGGeometry.h>
#include <cstdint>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <span>
#include <vector>

namespace macos::spaces {
  // Telar's Spaces on macOS, made of layers instead of Mission Control's Spaces, as the Linux
  // compositor makes its own. Each one has a stage, the layer shown while its display shows the
  // Space, and a shelf that is never shown, where the windows of its hidden tabs wait. A Space is
  // known by its stage's identifier. Stages sit at level 0, where their windows interleave with
  // the desktop's by the usual ordering and window levels: above the wallpapers, below Telar's
  // bars and menus, and in front of or behind unmanaged applications as the user clicks.
  //
  // Two layers belong to no Space. The backstage, never shown, keeps the windows the user sent
  // out of every layout. The takeover layer shows a backstage window alone over a display's
  // workspace while that display's stage is hidden; it is shown while any display has one.
  //
  // One per process: the UI thread, the Spaces observer and the window observer all use it.
  class VirtualSpaces final {
  public:
    static VirtualSpaces &get();

    // Off the UI thread: returns the windows of layers a Telar that is no longer running left
    // behind to their desktops, then makes the backstage and takeover layers.
    void prepare();
    // Off the UI thread. A display's first Space is shown at once.
    std::uint64_t create(std::uint32_t display);
    // Off the UI thread: returns other applications' windows to their desktop first.
    void remove(std::uint64_t space);
    // On stop: every other application's window back to its desktop, every layer destroyed.
    void release();

    // Shows the Space instead of the one its display showed, in one batched call. A takeover on
    // that display ends first.
    void show(std::uint64_t space);
    // Out of every layout and out of sight. A window taking over a display leaves it, and the
    // display gets its stage back when no window is left there.
    void sendToBackstage(std::span<const std::uint32_t> windows);
    // The windows alone on the display: into the takeover layer, the display's stage hidden. The
    // windows that took it over before return to the backstage.
    void takeOver(std::uint32_t display, std::span<const std::uint32_t> windows);
    // The display's stage back, and the windows that took it over to the backstage.
    void endTakeover(std::uint32_t display);
    // The windows taking over the display, if any.
    std::vector<std::uint32_t> takingOver(std::uint32_t display) const;
    // Whether the layer is the backstage or the takeover layer.
    bool offstage(std::uint64_t layer) const;
    std::uint64_t stage(std::uint64_t space) const;
    std::uint64_t shelf(std::uint64_t space) const;
    std::uint32_t display(std::uint64_t space) const;
    // The Space a window is in, from the first Space the window server lists for it: its stage or
    // shelf gives the Space itself, and a desktop the Space shown on the display under `point`,
    // where an application's new window appears. Full-screen Spaces stay as they are, and the
    // backstage and takeover layers give 0: their windows are on no Space.
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
    std::uint64_t backstage_ = 0;
    std::uint64_t takeover_ = 0;
    // The windows taking over each display.
    std::map<std::uint32_t, std::vector<std::uint32_t>> takeovers_;

    // Layer changes worked out under the lock and sent to the window server after it.
    struct Changes {
      std::uint64_t backstage = 0;
      std::vector<std::uint32_t> backstaged;
      std::uint64_t takeover = 0;
      std::vector<std::uint32_t> taking_over;
      std::vector<std::uint64_t> shown;
      std::vector<std::uint64_t> hidden;
    };

    VirtualSpaces() = default;
    // A copy, so nothing outlives the lock it was read under.
    std::optional<Space> find(std::uint64_t space) const;
    // Under the lock: ends the display's takeover and records what that changes.
    void endTakeover(std::uint32_t display, Changes &changes);
    // Under the lock: what sending the windows to the backstage changes for the displays they
    // were taking over.
    void leaveTakeovers(std::span<const std::uint32_t> windows, Changes &changes);
    // Under the lock: the backstage and takeover layers, or an error before prepare made them.
    Changes start() const;
    static void apply(const Changes &changes);
  };
} // namespace macos::spaces
