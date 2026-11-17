module;
#include "tbc/annotations.hpp"

// The tabs and panes the user works in: which tab comes next, where focus goes, how the panes of a
// tab share its area, the layout each workspace and tab was left with and restores, and what a
// tab strip and a pane wear on screen. The tabs and panes themselves are the session's model; the
// feature decides over them and the session carries out what it decided.
export module telar.gui.features.workbench;

export import :chrome;
export import :layouts;
export import :motions;
export import :progress;
export import :tabs;

import std;

import telar.base.memory.allocators;
import telar.gui.foundation.core;
import telar.gui.foundation.model;
import telar.wire.vocabulary;

namespace telar::gui::features::workbench {

  struct Access;

}

export namespace telar::gui::features::workbench {

  // The most tabs a session holds across its workspaces.
  inline constexpr std::size_t maximum_tabs = 256;

  // The tabs a session holds, each owned by the session.
  using Tabs = std::span<const Owned<Tab<Memory>, Memory>>;

  // The sizes a split leaves the pane it splits and gives the pane it adds.
  struct SplitSizes {
    TerminalSize existing;
    TerminalSize added;
  };

  // What a new bottom reservation did: whether it changed, and whether the panes on screen are
  // still to take the sizes it leaves them.
  struct Reservation {
    bool changed = false;
    bool resize = false;
  };

  // The area the panes share and what the attachment shelf reserves of it, the pane each
  // workspace was left on, the layouts saved for the tabs the session restores, and the layout a
  // tab being reloaded takes once the runtime describes it. Opaque: only the use cases below
  // reach it.
  class State {
    friend struct Access;

    WorkbenchGeometry geometry_;
    std::optional<PaneBottomReservation> reservation_;
    bool resize_pending_ = false;
    NavigationHistory history_;
    SavedLayouts saved_;
    std::optional<NavigationHistory::Bookmark> restoring_;
  };

  // ---- the area the panes share -------------------------------------------------------------

  // Where the panes go on the window and how many cells they have; read every frame.
  [[nodiscard]] TBC_HOT_PATH inline const WorkbenchGeometry& geometry(const State& state) noexcept;

  // The window gave the panes `geometry`; true when it changed.
  [[nodiscard]] bool place(State& state, WorkbenchGeometry geometry) noexcept;

  // The attachment shelf reserves `reservation` at the bottom of every tab in `tabs`.
  [[nodiscard]] Reservation reserve(State& state, std::optional<PaneBottomReservation> reservation, Tabs tabs) noexcept;

  // The panes on screen took the sizes the reservation leaves them.
  void resized(State& state) noexcept;

  // A tab the session adds reserves what the others do.
  void furnish(const State& state, Tab<Memory>& tab) noexcept;

  // The size a pane opened on its own takes; throws when the area is too small for one.
  [[nodiscard]] TerminalSize launchSize(const State& state);

  // ---- the panes of a tab -------------------------------------------------------------------

  // The sizes splitting pane `pane_id` of `tab` along `axis` gives; none when it does not fit.
  [[nodiscard]] std::optional<SplitSizes> splitSizes(const State& state, Tab<Memory>& tab, std::uint64_t pane_id, ClientLayoutAxis axis) noexcept;

  // Calls `visit(pane_id, size)` for each pane of `tab` on screen, with the size its place leaves
  // its terminal.
  template <typename Visit>
  void arrange(const State& state, Tab<Memory>& tab, Visit&& visit);

  // The pane next to the one `tab` focuses toward `direction`; 0 when there is none.
  [[nodiscard]] std::uint64_t neighbor(const State& state, Tab<Memory>& tab, PaneDirection direction) noexcept;

  // Moves the border of the pane `tab` focuses toward `direction`; false when a pane fills the tab
  // or the border cannot move.
  [[nodiscard]] bool resize(const State& state, Tab<Memory>& tab, PaneDirection direction) noexcept;

  // ---- the tabs of a workspace --------------------------------------------------------------

  // The tab at `location`, if the session holds it.
  [[nodiscard]] Tab<Memory>* find(Tabs tabs, TabLocation location) noexcept;

  // The tab at `index` in the order the workspace of `active` shows its tabs.
  [[nodiscard]] std::optional<TabLocation> tabAt(Tabs tabs, std::optional<TabLocation> active, std::size_t index) noexcept;

  // The tab `offset` places from `active` in the order its workspace shows its tabs, wrapping
  // around; none when the session holds no record of `active`.
  [[nodiscard]] std::optional<TabLocation> tabBeside(Tabs tabs, std::optional<TabLocation> active, std::int32_t offset) noexcept;

  // The tab that takes the place of the tab `closing` at `position` once it is gone: the next one,
  // else the previous one.
  [[nodiscard]] std::optional<TabLocation> tabAfterClose(Tabs tabs, TabLocation closing, std::uint16_t position) noexcept;

  // ---- the layouts the session keeps --------------------------------------------------------

  // A new connection: nothing the last one kept holds.
  void clear(State& state) noexcept;

  // The pane the user left `workspace` on, if the session remembers one.
  [[nodiscard]] std::optional<std::uint64_t> bookmark(const State& state, WorkspaceLocation workspace) noexcept;

  // The runtime no longer holds the pane the user left `workspace` on.
  void forget(State& state, WorkspaceLocation workspace) noexcept;

  // The user leaves the workspace `active` shows: its focused pane and layout are remembered, when
  // `active` holds one, and the layout of every loaded tab of `tabs` is saved for its return.
  void leave(State& state, Tabs tabs, std::optional<TabLocation> active, const Tab<Memory>* bookmarked) noexcept;

  // The pane the layout saved for `location` focuses, the one to open the tab at.
  [[nodiscard]] std::optional<std::uint64_t> savedPane(const State& state, TabLocation location);

  // The runtime gave back the layouts the session last retained: each one is saved for its tab, and
  // the active tab of each workspace is remembered. Throws when a layout is invalid or they do not
  // fit.
  void adopt(State& state, std::span<const ClientTabLayout> saved);

  // `tab` reloads from the runtime: its layout empties, and the one it restores once described is
  // the one saved for it, or the one its workspace was left with.
  void stage(State& state, Tab<Memory>& tab);

  // The runtime described `tab`: it takes the layout staged or saved for it, and `focus(pane_id)`
  // focuses the pane that layout focuses. The saved layout is then spent.
  template <typename Focus>
  void restore(State& state, Tab<Memory>& tab, Focus&& focus);

}

namespace telar::gui::features::workbench {

  struct Access {
    [[nodiscard]] static constexpr const WorkbenchGeometry& geometry(const State& state) noexcept {
      return state.geometry_;
    }

    [[nodiscard]] static constexpr WorkbenchGeometry& geometry(State& state) noexcept {
      return state.geometry_;
    }

    [[nodiscard]] static constexpr std::optional<PaneBottomReservation>& reservation(State& state) noexcept {
      return state.reservation_;
    }

    [[nodiscard]] static constexpr const std::optional<PaneBottomReservation>& reservation(const State& state) noexcept {
      return state.reservation_;
    }

    [[nodiscard]] static constexpr bool& resizePending(State& state) noexcept {
      return state.resize_pending_;
    }

    [[nodiscard]] static constexpr NavigationHistory& history(State& state) noexcept {
      return state.history_;
    }

    [[nodiscard]] static constexpr const NavigationHistory& history(const State& state) noexcept {
      return state.history_;
    }

    [[nodiscard]] static constexpr SavedLayouts& saved(State& state) noexcept {
      return state.saved_;
    }

    [[nodiscard]] static constexpr const SavedLayouts& saved(const State& state) noexcept {
      return state.saved_;
    }

    [[nodiscard]] static constexpr std::optional<NavigationHistory::Bookmark>& restoring(State& state) noexcept {
      return state.restoring_;
    }
  };

  inline const WorkbenchGeometry& geometry(const State& state) noexcept {
    return Access::geometry(state);
  }

  template <typename Visit>
  void arrange(const State& state, Tab<Memory>& tab, Visit&& visit) {
    const auto& geometry = Access::geometry(state);
    const auto fullscreen = tab.fullscreen ? std::optional{tab.focused_pane} : std::nullopt;
    const auto placements = tab.layout.arrange(geometry.cellArea(), geometry.layout_metrics, fullscreen);

    for (const auto& placement : placements) {
      if (const auto size = geometry.contentSize(placement.content)) {
        visit(placement.pane_id, *size);
      }
    }
  }

  template <typename Focus>
  void restore(State& state, Tab<Memory>& tab, Focus&& focus) {
    auto& restoring = Access::restoring(state);
    auto& saved_layouts = Access::saved(state);

    if (restoring && sameTab(restoring->location, tab.location)) {
      if (restoring->layout) {
        tab.layout.restore(restoring->layout->view());
        tab.fullscreen = restoring->fullscreen;
        focus(restoring->layout->focused_pane);
      }

      restoring.reset();
    } else if (const auto saved = saved_layouts.find(tab.location)) {
      tab.layout.restore(saved->nodes);
      tab.fullscreen = saved->fullscreen;
      focus(saved->focused_pane);
    }

    saved_layouts.forget(tab.location);
  }

}
