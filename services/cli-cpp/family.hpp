#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <string_view>

namespace telar::runtime::cli {

// The first word of a command line that names a group of commands, as `worktree`
// in `telar worktree create`. A word that is no family is a program to run in a
// pane of a window.
enum class Family : std::uint8_t {
  workspace,
  tab,
  pane,
  worktree,
  agent,
  exec,
  repository,
  project,
  file,
  machine,
  client,
  sidebar,
  workspace_list,
  layout,
  notification,
  command,
  config,
  plugin,
  integration,
  hook,
  cli,
  gui,
  server,
  runtime,
  diagnostics,
  history,
  proxy,
  api,
  clipboard,
  count
};

// Each family as it is typed, in the order of `Family`.
inline constexpr std::array<std::string_view, static_cast<std::size_t>(Family::count)> family_names{
    "workspace", "tab", "pane", "worktree", "agent", "exec", "repository", "project", "file", "machine",
    "client", "sidebar", "workspace-list", "layout", "notification", "command", "config", "plugin",
    "integration", "hook", "cli", "gui", "server", "runtime", "diagnostics", "history", "proxy", "api", "clipboard"};

inline std::string_view familyName(Family family) noexcept {
  return family_names.at(static_cast<std::size_t>(family));
}

inline std::optional<Family> parseFamily(std::string_view word) noexcept {
  for (std::size_t index = 0; index < family_names.size(); ++index) {
    if (family_names.at(index) == word) {
      return static_cast<Family>(index);
    }
  }

  return std::nullopt;
}

}
