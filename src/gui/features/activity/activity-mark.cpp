module telar.gui.features.activity;

import std;
import telar.config.core;
import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.base.ds;

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
    static constexpr ds::Array known{
        Known{.name = "nvim", .glyph = "", .tile = "#5fb095", .ink = "#0f1a16"},
        Known{.name = "vim", .glyph = "", .tile = "#5fb095", .ink = "#0f1a16"},
        Known{.name = "vi", .glyph = "", .tile = "#5fb095", .ink = "#0f1a16"},
        Known{.name = "git", .glyph = "", .tile = "#f37986", .ink = "#1a1627"},
        Known{.name = "lazygit", .glyph = "", .tile = "#f37986", .ink = "#1a1627"},
        Known{.name = "node", .glyph = "", .tile = "#83cd29", .ink = "#10210a"},
        Known{.name = "npm", .glyph = "", .tile = "#83cd29", .ink = "#10210a"},
        Known{.name = "python", .glyph = "", .tile = "#ffd43b", .ink = "#1f2d3d"},
        Known{.name = "python3", .glyph = "", .tile = "#ffd43b", .ink = "#1f2d3d"},
        Known{.name = "ruby", .glyph = "", .tile = "#cc342d", .ink = "#ffffff"},
        Known{.name = "irb", .glyph = "", .tile = "#cc342d", .ink = "#ffffff"},
        Known{.name = "bundle", .glyph = "", .tile = "#cc342d", .ink = "#ffffff"},
        Known{.name = "docker", .glyph = "", .tile = "#2496ed", .ink = "#ffffff"},
        Known{.name = "cargo", .glyph = "", .tile = "#dea584", .ink = "#1a1627"},
        Known{.name = "go", .glyph = "", .tile = "#00add8", .ink = "#08252b"},
        Known{.name = "bun", .glyph = "B", .tile = "#fbf0df", .ink = "#1a1627"},
    };

    for (const auto& entry : known) {
      if (entry.name == name) {
        return {.provider = AgentProvider::unknown, .glyph = entry.glyph, .tile = entry.tile, .ink = entry.ink};
      }
    }

    return {};
  }

}
