module telar.gui.features.workbench;

import std;
import telar.tbc;
import telar.base.memory.allocators;
import telar.base.text.utf8;
import telar.gui.foundation.model;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::workbench {

  namespace {

    // The tabs of the workspace `active` shows, in the order it shows them, into `output`, which views
    // them for as long as `tabs` does, region `a`.
    std::size_t ordered(tbc::view<Tabs, tbc::lt::a> tabs, ds::Option<TabLocation> active, tbc::view<ds::Array<const Tab<Memory>*, maximum_tabs>&, tbc::lt::a> output) noexcept {
      std::size_t count = 0;

      if (!active) {
        return count;
      }

      for (const auto& tab : tabs) {
        if (sameWorkspace(tab->location.workspace, active->workspace)) {
          output.atMut(count++) = &tab.get();
        }
      }

      std::sort(output.dataMut(), output.dataMut() + count, [](const auto* left, const auto* right) {
        return left->position != right->position ? left->position < right->position : left->location.tab_id < right->location.tab_id;
      });

      return count;
    }

  }

  bool place(State& state, WorkbenchGeometry geometry) noexcept {
    auto& current = Access::geometry(state);
    if (current == geometry) {
      return false;
    }

    current = geometry;

    return true;
  }

  Reservation reserve(State& state, ds::Option<PaneBottomReservation> reservation, std::span<ds::Box<Tab<Memory>, Memory>> tabs) noexcept {
    auto& current = Access::reservation(state);
    const auto changed = current != reservation;

    if (changed) {
      current = reservation;
      Access::resizePending(state) = true;
      for (auto& tab : tabs) {
        tab.getMut().layout.setBottomReservation(reservation);
      }
    }

    return {.changed = changed, .resize = Access::resizePending(state)};
  }

  void resized(State& state) noexcept {
    Access::resizePending(state) = false;
  }

  void furnish(const State& state, Tab<Memory>& tab) noexcept {
    tab.layout.setBottomReservation(Access::reservation(state));
  }

  TerminalSize launchSize(const State& state) {
    const auto size = Access::geometry(state).launchSize();
    if (!size) {
      throw std::runtime_error{"TerminalTooSmall"};
    }

    return *size;
  }

  ds::Option<SplitSizes> splitSizes(const State& state, Tab<Memory>& tab, std::uint64_t pane_id, ClientLayoutAxis axis) noexcept {
    const auto& geometry = Access::geometry(state);
    const auto fullscreen = tab.fullscreen ? ds::Option{tab.focused_pane} : ds::none;
    const auto bounds = tab.layout.prospectiveSplit(geometry.cellArea(), axis, pane_id, geometry.layout_metrics, fullscreen);
    if (!bounds) {
      return ds::none;
    }

    const auto existing = geometry.contentSize(bounds->existing_content);
    const auto added = geometry.contentSize(bounds->added_content);
    if (!existing || !added) {
      return ds::none;
    }

    return SplitSizes{.existing = *existing, .added = *added};
  }

  std::uint64_t neighbor(const State& state, Tab<Memory>& tab, PaneDirection direction) noexcept {
    const auto& geometry = Access::geometry(state);

    return tab.layout.focusTarget(geometry.cellArea(), geometry.layout_metrics, {.pane_id = tab.focused_pane, .direction = direction, .fullscreen = tab.fullscreen});
  }

  bool resize(const State& state, Tab<Memory>& tab, PaneDirection direction) noexcept {
    const auto& geometry = Access::geometry(state);

    return !tab.fullscreen && tab.layout.resize(tab.focused_pane, direction, geometry.cellArea(), geometry.layout_metrics);
  }

  ds::Option<TabLocation> tabAt(Tabs tabs, ds::Option<TabLocation> active, std::size_t index) noexcept {
    ds::Array<const Tab<Memory>*, maximum_tabs> sorted{};
    const auto count = ordered(tabs, active, sorted);

    return index < count ? ds::Option{sorted[index]->location} : ds::none;
  }

  ds::Option<TabLocation> tabBeside(Tabs tabs, ds::Option<TabLocation> active, std::int32_t offset) noexcept {
    ds::Array<const Tab<Memory>*, maximum_tabs> sorted{};
    const auto count = ordered(tabs, active, sorted);
    const auto* current = active ? find(tabs, *active) : nullptr;
    const auto* const found = std::find(sorted.begin(), sorted.begin() + count, current);
    if (count == 0 || found == sorted.begin() + count) {
      return ds::none;
    }

    const auto index = static_cast<std::int64_t>(found - sorted.begin());
    const auto size = static_cast<std::int64_t>(count);
    const auto next = (((index + offset) % size) + size) % size;

    return sorted[static_cast<std::size_t>(next)]->location;
  }

  ds::Option<TabLocation> tabAfterClose(Tabs tabs, TabLocation closing, std::uint16_t position) noexcept {
    const Tab<Memory>* previous = nullptr;
    const Tab<Memory>* next = nullptr;

    for (const auto& tab : tabs) {
      if (!sameWorkspace(tab->location.workspace, closing.workspace) || sameTab(tab->location, closing)) {
        continue;
      }

      if (tab->position > position && (next == nullptr || tab->position < next->position)) {
        next = &tab.get();
      } else if (tab->position < position && (previous == nullptr || tab->position > previous->position)) {
        previous = &tab.get();
      }
    }

    const auto* selected = next == nullptr ? previous : next;

    return selected == nullptr ? ds::none : ds::Option{selected->location};
  }

  void clear(State& state) noexcept {
    Access::restoring(state).reset();
    Access::history(state).clear();
    Access::saved(state).clear();
  }

  ds::Option<std::uint64_t> bookmark(const State& state, WorkspaceLocation workspace) noexcept {
    const auto* found = Access::history(state).find(workspace);

    return found == nullptr ? ds::none : ds::Option{found->pane_id};
  }

  void forget(State& state, WorkspaceLocation workspace) noexcept {
    Access::history(state).forget(workspace);
  }

  void leave(State& state, Tabs tabs, ds::Option<TabLocation> active, const Tab<Memory>* bookmarked) noexcept {
    if (bookmarked != nullptr) {
      Access::history(state).remember({.location = bookmarked->location, .pane_id = bookmarked->focused_pane, .layout = NavigationHistory::Layout{bookmarked->layout, bookmarked->focused_pane}, .fullscreen = bookmarked->fullscreen});
    }

    for (const auto& known : tabs) {
      if (known->loaded && known->focused_pane != 0) {
        Access::saved(state).retain({.location = known->location, .pane_id = known->focused_pane, .focused_pane = known->focused_pane, .workspace_active = active && sameTab(*active, known->location), .fullscreen = known->fullscreen, .nodes = known->layout.nodes()});
      }
    }

    Access::restoring(state).reset();
  }

  ds::Option<std::uint64_t> savedPane(const State& state, TabLocation location) {
    const auto saved = Access::saved(state).find(location);

    return saved ? ds::Option{saved->pane_id} : ds::none;
  }

  void adopt(State& state, std::span<const ClientTabLayout> saved) {
    for (const auto& tab : saved) {
      PaneLayout validated;

      validated.restore(tab.nodes);
      if (!validated.contains(tab.focused_pane)) {
        throw EncodingError{"InvalidClientLayoutFocus"};
      }

      if (!Access::saved(state).remember({.location = tab.location, .pane_id = tab.focused_pane, .focused_pane = tab.focused_pane, .workspace_active = tab.workspace_active, .fullscreen = tab.fullscreen, .nodes = tab.nodes})) {
        throw EncodingError{"TooManySavedLayouts"};
      }

      if (tab.workspace_active) {
        Access::history(state).remember({.location = tab.location, .pane_id = tab.focused_pane, .layout = NavigationHistory::Layout{tab.nodes, tab.focused_pane}, .fullscreen = tab.fullscreen});
      }
    }
  }

  void stage(State& state, Tab<Memory>& tab) {
    auto& restoring = Access::restoring(state);

    restoring.reset();
    if (const auto saved = Access::saved(state).find(tab.location)) {
      restoring = {.location = saved->location, .pane_id = saved->focused_pane, .layout = NavigationHistory::Layout{saved->nodes, saved->focused_pane}, .fullscreen = saved->fullscreen};
    } else if (const auto* bookmark = Access::history(state).find(tab.location.workspace); bookmark != nullptr && sameTab(bookmark->location, tab.location)) {
      restoring = *bookmark;
    }

    tab.layout.restore({});
    tab.focused_pane = 0;
    tab.fullscreen = false;
    tab.loaded = false;
    tab.loading = false;
  }

}
