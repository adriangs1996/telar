module telar.gui.features.activity;

import std;
import telar.gui.foundation.model;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::activity {

  tbc::view<const Agent<Memory>*, tbc::lt::a> find(tbc::view<std::span<const Agent<Memory>>, tbc::lt::a> agents, std::uint64_t pane_id, ds::Option<std::uint64_t> generation) noexcept {
    const auto agent = std::ranges::find_if(agents, [&](const auto& entry) {
      return entry.pane_id == pane_id && (!generation || entry.pane_generation == *generation);
    });

    return agent == agents.end() ? nullptr : &*agent;
  }

  tbc::view<const Agent<Memory>*, tbc::lt::a> focused(tbc::view<std::span<const Agent<Memory>>, tbc::lt::a> agents, const Tab<Memory>& tab) noexcept {
    const auto agent = std::ranges::find_if(agents, [&](const auto& candidate) {
      return candidate.pane_id == tab.focused_pane && sameTab(candidate.location, tab.location);
    });

    return agent == agents.end() ? nullptr : &*agent;
  }

  ds::Option<std::uint64_t> workspaceOf(std::span<const Agent<Memory>> agents, std::span<const ListedPane> listed, std::uint64_t pane_id, ds::Option<std::uint64_t> generation) noexcept {
    const auto* agent = find(agents, pane_id, generation);
    const auto pane = std::ranges::find_if(listed, [&](const auto& entry) {
      return entry.pane_id == pane_id && (!generation || entry.pane_generation == *generation);
    });

    const auto location = agent != nullptr ? ds::Option{agent->location} : pane != listed.end() ? ds::Option{pane->location}
                                                                                                   : ds::none;

    return location && location->workspace.kind == WorkspaceLocation::Kind::workspace ? ds::Option{location->workspace.id} : ds::none;
  }

}
