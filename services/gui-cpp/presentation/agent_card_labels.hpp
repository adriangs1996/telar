#pragma once

#include "telar_client/serializers/telar_messages.hpp"
#include "text/bounded_text.hpp"
#include <cstddef>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

struct AgentCardLabels {
  static constexpr std::string_view generic_name = "Agent";
  static constexpr std::string_view separator = " · ";
  static constexpr std::string_view coordinator_suffix = " · coordinator";
  static constexpr std::size_t workspace_capacity = 48;
  static constexpr std::size_t machine_capacity = 32;
  static constexpr std::size_t suffix_capacity = 32;
  using Project = BoundedText<workspace_capacity + machine_capacity + suffix_capacity>;

  [[nodiscard]] static std::string_view title(std::string_view session, std::string_view display_name) noexcept {
    if (!session.empty()) {
      return session;
    }

    return display_name.empty() ? generic_name : display_name;
  }

  [[nodiscard]] static std::string_view providerGlyph(AgentProvider provider, std::string_view custom) noexcept {
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

  [[nodiscard]] static std::string_view project(std::string_view workspace, std::string_view machine, bool coordinator, Project &storage) {
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
    } catch (const std::length_error &) {
      return machine.empty() ? workspace : machine;
    }
  }
};

}
