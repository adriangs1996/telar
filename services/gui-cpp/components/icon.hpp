#pragma once

#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <array>
#include <string_view>

namespace telar::gui::components {

struct Icon {
  std::string_view name;
  std::string_view glyph;
  AgentProvider provider = AgentProvider::unknown;
  bool telar = false;

  [[nodiscard]] static Icon find(std::string_view name) noexcept {
    const auto *const found = std::ranges::find(values, name, &Icon::name);

    return found == values.end() ? Icon{.name = {}, .glyph = {}} : *found;
  }

private:
  static const std::array<Icon, 32> values;
};

inline constexpr std::array<Icon, 32> Icon::values = std::to_array<Icon>({
    {.name = "sidebar_collapse", .glyph = ""},
    {.name = "sidebar_expand", .glyph = ""},
    {.name = "workspace_menu", .glyph = ""},
    {.name = "proxy_active", .glyph = ""},
    {.name = "cpu", .glyph = ""},
    {.name = "memory", .glyph = ""},
    {.name = "battery_empty", .glyph = ""},
    {.name = "battery_quarter", .glyph = ""},
    {.name = "battery_half", .glyph = ""},
    {.name = "battery_three_quarters", .glyph = ""},
    {.name = "battery_full", .glyph = ""},
    {.name = "provider_unknown", .glyph = ""},
    {.name = "provider_claude", .glyph = "", .provider = AgentProvider::claude},
    {.name = "provider_codex", .glyph = "", .provider = AgentProvider::codex},
    {.name = "provider_pi", .glyph = "󰏿", .provider = AgentProvider::pi},
    {.name = "provider_cursor", .glyph = "󰋘", .provider = AgentProvider::cursor},
    {.name = "provider_opencode", .glyph = "󰝣", .provider = AgentProvider::opencode},
    {.name = "app_terminal", .glyph = ""},
    {.name = "app_editor", .glyph = ""},
    {.name = "app_git", .glyph = ""},
    {.name = "agent_unknown", .glyph = ""},
    {.name = "agent_working_0", .glyph = ""},
    {.name = "agent_working_1", .glyph = ""},
    {.name = "agent_working_2", .glyph = ""},
    {.name = "agent_working_3", .glyph = ""},
    {.name = "agent_blocked", .glyph = ""},
    {.name = "agent_ready", .glyph = ""},
    {.name = "agent_done", .glyph = ""},
    {.name = "agent_failed", .glyph = ""},
    {.name = "close", .glyph = ""},
    {.name = "pane_fullscreen", .glyph = ""},
    {.name = "telar_mark", .glyph = "▣", .telar = true},
});

}
