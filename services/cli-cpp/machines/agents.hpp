#pragma once

#include "platform.hpp"
#include "remote_shell.hpp"
#include "setup_report.hpp"

namespace telar::runtime::cli::machine {

inline constexpr auto agent_names = std::to_array<std::string_view>({"claude", "codex", "pi", "opencode", "cursor"});
inline constexpr auto agent_commands = std::to_array<std::string_view>({"claude", "codex", "pi", "opencode", "cursor-agent"});

inline std::set<std::string> localAgents() {
  std::set<std::string> found;
  const auto *path = std::getenv("PATH");
  if (!path) {
    return found;
  }

  for (std::size_t agent = 0; agent < agent_names.size(); ++agent) {
    std::string_view directories{path};
    for (;;) {
      const auto colon = directories.find(':');
      const auto directory = directories.substr(0, colon);
      if (!directory.empty() && ::access((std::string{directory} + "/" + std::string{agent_commands[agent]}).c_str(), X_OK) == 0) {
        found.emplace(agent_names[agent]);
        break;
      }

      if (colon == std::string_view::npos) {
        break;
      }

      directories.remove_prefix(colon + 1);
    }
  }

  return found;
}

inline std::string names(const std::set<std::string> &agents) {
  std::string text;
  for (const auto agent : agent_names) {
    if (agents.contains(std::string{agent})) {
      if (!text.empty()) {
        text += ", ";
      }

      text += agent;
    }
  }

  return text;
}

struct AgentInstaller {
  std::vector<std::string_view> tools;
  std::string script;
  bool musl = true;
};

inline AgentInstaller installerFor(std::string_view agent) {
  if (agent == "claude") {
    return {.tools = {"curl", "bash"}, .script = R"(if [ -f /etc/alpine-release ]; then
    if [ ! -e /usr/lib/libstdc++.so.6 ] || ! command -v rg >/dev/null 2>&1; then
        echo 'Claude Code on Alpine needs `apk add libgcc libstdc++ ripgrep` (as root) first' >&2
        exit 1
    fi
fi
fetch https://claude.ai/install.sh
bash "$installer" </dev/null
)"};
  }
  if (agent == "codex") {
    return {.tools = {"curl", "tar"}, .script = "fetch https://chatgpt.com/codex/install.sh\nCODEX_NON_INTERACTIVE=1 sh \"$installer\" </dev/null\n"};
  }
  if (agent == "pi") {
    return {.tools = {"curl", "node", "npm"}, .script = "fetch https://pi.dev/install.sh\nsh \"$installer\" </dev/null\n"};
  }
  if (agent == "opencode") {
    return {.tools = {"curl", "bash", "tar"}, .script = "fetch https://opencode.ai/install\nbash \"$installer\" --no-modify-path </dev/null\n"};
  }
  return {.tools = {"curl", "bash"}, .script = "fetch https://cursor.com/install\nbash \"$installer\" </dev/null\n", .musl = false};
}

inline std::optional<std::string> missingPrerequisite(const Platform &platform, std::string_view agent, const AgentInstaller &installer) {
  if (platform.libc == "musl" && !installer.musl) {
    return "its binary needs glibc and this machine has musl";
  }
  for (const auto tool : installer.tools) {
    if (!platform.tools.contains(std::string{tool})) {
      if (tool == "node" || tool == "npm") {
        return "Node.js 22.19 or newer with npm is missing there; its installer would need sudo or a terminal to add it";
      }
      return std::string{tool} + " is missing there";
    }
  }

  if (agent == "pi") {
    auto text = platform.node ? std::string_view{*platform.node} : std::string_view{};
    while (text.starts_with('v')) {
      text.remove_prefix(1);
    }
    unsigned major = 0;
    unsigned minor = 0;
    const auto first = std::from_chars(text.data(), text.data() + text.size(), major);
    if (first.ec != std::errc{} || first.ptr == text.data() + text.size() || *first.ptr != '.') {
      return "Node.js there is older than 22.19";
    }
    const auto second = std::from_chars(first.ptr + 1, text.data() + text.size(), minor);
    constexpr unsigned required_major = 22;
    constexpr unsigned required_minor = 19;
    if (second.ec != std::errc{} || major < required_major || (major == required_major && minor < required_minor)) {
      return "Node.js there is older than 22.19";
    }
  }

  return std::nullopt;
}

template <Allocator Memory>
bool installAgents(Memory &memory, SetupReport &report, const std::string &destination, const Platform &platform, const std::set<std::string> &wanted) {
  if (wanted.empty()) {
    report.end(Step::agents, Status::skipped, "no agent on this machine's PATH to install there");
    return false;
  }
  bool ran = false;
  bool failed = false;
  for (const auto name : agent_names) {
    const std::string agent{name};
    if (!wanted.contains(agent)) {
      continue;
    }
    if (const auto existing = platform.agents.find(agent); existing != platform.agents.end()) {
      report.note(Step::agents, agent + ": already at " + existing->second);
      continue;
    }

    const auto installer = installerFor(agent);
    if (const auto missing = missingPrerequisite(platform, agent, installer)) {
      report.note(Step::agents, agent + ": not installed: " + *missing);
      continue;
    }

    ran = true;
    report.progress("installing " + agent + " there with its official installer");
    static constexpr std::string_view prelude = R"Agent(set -eu
installer=$(mktemp "${TMPDIR:-/tmp}/telar-agent-installer.XXXXXX")
trap 'rm -f "$installer"' EXIT
fetch() {
    curl --proto '=https' --tlsv1.2 -fsSL "$1" -o "$installer"
}
)Agent";
    try {
      const auto output = runScript(memory, destination, std::string{prelude} + installer.script, install_timeout);
      if (output.status == 0) {
        report.note(Step::agents, agent + ": installed with its official installer");
      } else {
        report.note(Step::agents, agent + ": its installer failed: " + std::string{output.errorLine()});
        failed = true;
      }
    } catch (const std::exception &error) {
      report.note(Step::agents, agent + ": its installer did not run to the end: " + error.what());
      failed = true;
    }
  }

  report.end(Step::agents, failed ? Status::failed : ran ? Status::changed
                                                         : Status::ok,
             std::to_string(wanted.size()) + " wanted: " + names(wanted));
  return ran;
}

template <Allocator Memory>
void integrateAgents(Memory &memory, SetupReport &report, const std::string &destination, const Platform &platform) {
  if (platform.agents.empty()) {
    report.end(Step::integrations, Status::skipped, "no agent there");
    return;
  }

  bool changed = false;
  bool failed = false;
  std::set<std::string> present;
  for (const auto name : agent_names) {
    const std::string agent{name};
    if (!platform.agents.contains(agent)) {
      continue;
    }

    present.insert(agent);
    try {
      const auto output = runScript(memory, destination, assign("telar", platform.target) + assign("agent", agent) + "exec \"$telar\" integration install \"$agent\"\n");
      if (output.status != 0) {
        report.note(Step::integrations, agent + ": " + std::string{output.errorLine()});
        failed = true;
        continue;
      }

      const bool unchanged = whole(output).contains("already present");
      changed = changed || !unchanged;
      report.note(Step::integrations, agent + (unchanged ? ": already integrated" : ": integrated"));
    } catch (const std::exception &error) {
      report.note(Step::integrations, agent + ": " + error.what());
      failed = true;
    }
  }

  report.end(Step::integrations, failed ? Status::failed : changed ? Status::changed
                                                                   : Status::ok,
             names(present));
}

}
