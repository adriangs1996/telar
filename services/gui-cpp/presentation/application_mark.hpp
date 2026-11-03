#pragma once

#include "telar_client/serializers/telar_messages.hpp"
#include "telar_config/agents/provider.hpp"
#include <string_view>

namespace telar::gui {

struct ApplicationMark {
  static constexpr float dimmed_alpha = 0.6F;
  static constexpr float atlas_cell_side = 20;
  static constexpr int minimum_cell = 8;
  static constexpr int maximum_cell = 96;

  AgentProvider provider = AgentProvider::unknown;
  std::string_view glyph = "\uea85";

  [[nodiscard]] bool followsTheme() const noexcept {
    return provider == AgentProvider::codex || provider == AgentProvider::cursor || provider == AgentProvider::opencode;
  }

  [[nodiscard]] static ApplicationMark forApplication(std::string_view name) noexcept {
    auto provider = runtime::builtinProviderFromExecutable(name);
    if (provider == AgentProvider::unknown) {
      for (const auto candidate : {AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode}) {
        if (name == runtime::describeProvider(candidate).display_name) {
          provider = candidate;
          break;
        }
      }
    }

    switch (provider) {
    case AgentProvider::claude:
      return {.provider = provider, .glyph = "\uec20"};
    case AgentProvider::codex:
      return {.provider = provider, .glyph = "\uea85"};
    case AgentProvider::pi:
      return {.provider = provider, .glyph = "\U000f03ff"};
    case AgentProvider::cursor:
      return {.provider = provider, .glyph = "\U000f02d8"};
    case AgentProvider::opencode:
      return {.provider = provider, .glyph = "\U000f0763"};
    default:
      break;
    }

    if (name == "nvim" || name == "vim" || name == "vi") {
      return {.provider = AgentProvider::unknown, .glyph = "\ue62b"};
    }

    if (name == "git" || name == "lazygit") {
      return {.provider = AgentProvider::unknown, .glyph = "\ue702"};
    }

    return {};
  }
};

}
