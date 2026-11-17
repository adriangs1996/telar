module telar.gui.features.activity;

import std;
import telar.config.core;
import telar.gui.foundation.core;
import telar.wire.vocabulary;

namespace telar::gui::features::activity {

  bool ApplicationMark::followsTheme() const noexcept {
    return provider == AgentProvider::codex || provider == AgentProvider::pi || provider == AgentProvider::cursor || provider == AgentProvider::opencode;
  }

  ApplicationMark ApplicationMark::forApplication(std::string_view name) noexcept {
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
      return {.provider = provider, .glyph = "", .tile = "#d97757", .ink = "#1a1627"};
    case AgentProvider::codex:
      return {.provider = provider, .glyph = "", .tile = "#f2f1f5", .ink = "#1a1627"};
    case AgentProvider::pi:
      return {.provider = provider, .glyph = "\U000f03ff", .tile = "#e5ca93", .ink = "#1a1627"};
    case AgentProvider::cursor:
      return {.provider = provider, .glyph = "\U000f02d8", .tile = "#e5e3ee", .ink = "#1a1627"};
    case AgentProvider::opencode:
      return {.provider = provider, .glyph = "\U000f0763", .tile = "#99baf8", .ink = "#1a1627"};
    default:
      break;
    }

    struct Known {
      std::string_view name;
      std::string_view glyph;
      std::string_view tile;
      std::string_view ink;
    };

    // Terminal programs have no operating system icon of their own.
    static constexpr std::array known{
        Known{"nvim", "", "#5fb095", "#0f1a16"},
        Known{"vim", "", "#5fb095", "#0f1a16"},
        Known{"vi", "", "#5fb095", "#0f1a16"},
        Known{"git", "", "#f37986", "#1a1627"},
        Known{"lazygit", "", "#f37986", "#1a1627"},
        Known{"node", "", "#83cd29", "#10210a"},
        Known{"npm", "", "#83cd29", "#10210a"},
        Known{"python", "", "#ffd43b", "#1f2d3d"},
        Known{"python3", "", "#ffd43b", "#1f2d3d"},
        Known{"ruby", "", "#cc342d", "#ffffff"},
        Known{"irb", "", "#cc342d", "#ffffff"},
        Known{"bundle", "", "#cc342d", "#ffffff"},
        Known{"docker", "", "#2496ed", "#ffffff"},
        Known{"cargo", "", "#dea584", "#1a1627"},
        Known{"go", "", "#00add8", "#08252b"},
        Known{"bun", "B", "#fbf0df", "#1a1627"},
    };

    for (const auto& entry : known) {
      if (entry.name == name) {
        return {.provider = AgentProvider::unknown, .glyph = entry.glyph, .tile = entry.tile, .ink = entry.ink};
      }
    }

    return {};
  }

}
