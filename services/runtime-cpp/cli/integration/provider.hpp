#pragma once

#include "telar_base/memory/allocator.hpp"
#include "telar_config/agents/provider.hpp"
#include "telar_platform/process_environment.hpp"

namespace telar::runtime::cli::integration {

struct Provider {
  std::string_view name;
  const char *environment = nullptr;
  std::string_view home_directory;
  std::string_view environment_suffix{};
  std::string_view file;
  std::span<const std::string_view> events{};
  std::span<const std::string_view> worktree_events{};
  std::string_view timeout{};
  bool flat_hooks = false;
  std::string_view launch_note{};

  static Provider describe(AgentProvider provider) {
    switch (provider) {
    case AgentProvider::claude:
      return {.name = "claude", .environment = "CLAUDE_CONFIG_DIR", .home_directory = ".claude", .file = "settings.json", .events = claude_events, .worktree_events = claude_worktree_events, .timeout = "5"};
    case AgentProvider::codex:
      return {.name = "codex", .environment = "CODEX_HOME", .home_directory = ".codex", .file = "hooks.json", .events = codex_events, .timeout = "3", .launch_note = "Codex runs its hooks in its shared daemon, outside any pane, unless it starts with --no-daemon; launch it that way, for instance with `alias codex='codex --no-daemon'`"};
    case AgentProvider::cursor:
      return {.name = "cursor", .home_directory = ".cursor", .file = "hooks.json", .events = cursor_events, .timeout = "5", .flat_hooks = true};
    case AgentProvider::pi:
      return {.name = "pi", .environment = "PI_CODING_AGENT_DIR", .home_directory = ".pi/agent", .file = "extensions/telar.ts"};
    case AgentProvider::opencode:
      return {.name = "opencode", .environment = "XDG_CONFIG_HOME", .home_directory = ".config/opencode", .environment_suffix = "/opencode", .file = "plugins/telar.ts"};
    default:
      throw std::invalid_argument{"Unknown integration provider"};
    }
  }

  template <Allocator Memory, EnvironmentLookup Environment>
  String<Memory> root(Memory &memory, const Environment &environment, bool legacy = false) const {
    String<Memory> result{AllocatorRef<char, Memory>{memory}};
    if (this->environment != nullptr && !legacy) {
      result = environment.lookup(this->environment);
      if (!result.empty()) {
        result += environment_suffix;
        return result;
      }
    }

    result = environment.lookup("HOME");
    if (result.empty()) {
      throw std::invalid_argument{"Home directory unavailable for integration"};
    }

    result += '/';
    result += home_directory;
    return result;
  }

private:
  static constexpr auto claude_events = std::to_array<std::string_view>({"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Notification", "SessionEnd", "CwdChanged"});
  static constexpr auto claude_worktree_events = std::to_array<std::string_view>({"WorktreeCreate", "WorktreeRemove"});
  static constexpr auto codex_events = std::to_array<std::string_view>({"SessionStart", "UserPromptSubmit", "PermissionRequest", "PreToolUse", "PostToolUse", "Stop", "Interrupt", "SubagentStop", "SessionEnd"});
  static constexpr auto cursor_events = std::to_array<std::string_view>({"sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure", "stop", "sessionEnd"});
};

}
