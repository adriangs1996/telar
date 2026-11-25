module telar.gui.foundation.agents;

import std;

import telar.tbc;
import telar.wire.vocabulary;

namespace telar::gui::inline foundation::inline agents {

  tbc::val_a<std::string_view> AgentCardLabels::title(tbc::val_a<std::string_view> session, tbc::val_a<std::string_view> display_name) noexcept {
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
    case AgentProvider::antigravity:
      return "\u2227";
    case AgentProvider::unknown:
    case AgentProvider::last_custom:
      break;
    }

    // A custom provider's number has no enumerator of its own.
    return "?";
  }

  tbc::val_a<std::string_view> AgentCardLabels::project(tbc::val_a<std::string_view> workspace, tbc::val_a<std::string_view> machine, bool coordinator, tbc::mut_a<Project> storage) {
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
