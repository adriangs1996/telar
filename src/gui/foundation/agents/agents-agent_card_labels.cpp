module telar.gui.foundation.agents;

import std;

import telar.tbc;
import telar.wire.vocabulary;

namespace telar::gui::inline foundation::inline agents {

  tbc::view<std::string_view, tbc::lt::a> AgentCardLabels::title(tbc::view<std::string_view, tbc::lt::a> session, tbc::view<std::string_view, tbc::lt::a> display_name) noexcept {
    if (!session.empty()) {
      return session;
    }

    return display_name.empty() ? generic_name : display_name;
  }

  std::string_view AgentCardLabels::providerGlyph(AgentProvider provider, std::string_view custom) noexcept {
    if (!custom.empty()) {
      return custom;
    }

    switch (provider) {
    case AgentProvider::claude:
      return "\u2733";
    case AgentProvider::codex:
      return "\u25c6";
    case AgentProvider::pi:
      return "\u03c0";
    case AgentProvider::cursor:
      return "\u2b22";
    case AgentProvider::opencode:
      return "\u25a3";
    default:
      return "?";
    }
  }

  tbc::view<std::string_view, tbc::lt::a> AgentCardLabels::project(tbc::view<std::string_view, tbc::lt::a> workspace, tbc::view<std::string_view, tbc::lt::a> machine, bool coordinator, tbc::view<Project&, tbc::lt::a> storage) {
    storage.truncate(0);
    try {
      if (!machine.empty()) {
        storage.append(machine);
        storage.append(separator);
      }

      storage.append(workspace);
      if (coordinator) {
        storage.append(coordinator_suffix);
      }

      return storage.view();
    } catch (const std::length_error&) {
      return machine.empty() ? workspace : machine;
    }
  }

}
