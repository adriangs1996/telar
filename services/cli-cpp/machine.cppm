module;
#include <stdlib.h>

#include <cstdint>
#include <cerrno>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <limits.h>
#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif
#include <sys/stat.h>
#include <cstddef>
#include <cstring>
#include <new>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#include <sys/file.h>
#include <sys/un.h>
#include <openssl/sha.h>




#include <cctype>

#include <sys/socket.h>
#include <sys/time.h>

#include "help_texts.hpp"
#include "machine_assets.hpp"


export module telar.cli.machine;

import std;

export import telar.cli.machine_ssh;


import telar.cli.machine_ssh;


export import telar.cli.command_limit;


export import telar.cli.window;


export import telar.cli.integration.settings;


export import telar.cli.runtime_observer;


export import telar.platform;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: machines/platform.cppm
export {
namespace telar::runtime::cli::machine {

struct Platform {
  std::string os;
  std::string arch;
  std::string libc;
  std::string home;
  std::string target;
  std::optional<std::string> installed;
  std::optional<std::string> node;
  std::set<std::string> tools;
  std::map<std::string, std::string> agents;

  inline static Platform parse(std::string_view output) {
    constexpr std::size_t max_output = 8 * 1024;
    if (output.size() > max_output) {
      throw CommandError{"MachineProbeUnreadable"};
    }

    Platform result;
    while (output.ends_with('\n')) {
      output.remove_suffix(1);
    }

    for (;;) {
      const auto end = output.find('\n');
      const auto line = output.substr(0, end);
      const auto equals = line.find('=');
      if (equals == std::string_view::npos) {
        throw CommandError{"MachineProbeUnreadable"};
      }

      const auto key = line.substr(0, equals);
      const auto value = line.substr(equals + 1);
      if (value.size() > MachineLimits::program_bytes || std::ranges::any_of(value, [](unsigned char byte) { return byte < 0x20 || byte == 0x7f; })) {
        throw CommandError{"MachineProbeUnreadable"};
      }

      const auto absolute = [&] {
        if (value.empty() || value.front() != '/') {
          throw CommandError{"MachineProbeUnreadable"};
        }

        return std::string{value};
      };
      if (key == "os") {
        if (value == "Linux") {
          result.os = "linux";
        } else if (value == "Darwin") {
          result.os = "macos";
        } else {
          throw CommandError{"UnsupportedMachineSystem"};
        }
      } else if (key == "arch") {
        if (value == "x86_64" || value == "amd64") {
          result.arch = "x86_64";
        } else if (value == "aarch64" || value == "arm64") {
          result.arch = "aarch64";
        } else {
          throw CommandError{"UnsupportedMachineArchitecture"};
        }
      } else if (key == "libc") {
        if (value != "gnu" && value != "musl") {
          throw CommandError{"MachineProbeUnreadable"};
        }

        result.libc = value;
      } else if (key == "home") {
        result.home = absolute();
      } else if (key == "target") {
        result.target = absolute();
      } else if (key == "installed") {
        result.installed = value;
      } else if (key == "node") {
        result.node = value;
      } else if (key == "tool") {
        if (value != "curl" && value != "tar" && value != "bash" && value != "node" && value != "npm") {
          throw CommandError{"MachineProbeUnreadable"};
        }

        result.tools.emplace(value);
      } else if (key == "agent") {
        const auto colon = value.find(':');
        const auto agent = value.substr(0, colon);
        if (colon == std::string_view::npos || std::ranges::find(machine_agent_names, agent) == machine_agent_names.end() || colon + 1 == value.size() || value[colon + 1] != '/') {
          throw CommandError{"MachineProbeUnreadable"};
        }

        result.agents[std::string{agent}] = value.substr(colon + 1);
      } else {
        throw CommandError{"MachineProbeUnreadable"};
      }

      if (end == std::string_view::npos) {
        break;
      }

      output.remove_prefix(end + 1);
    }

    if (result.os.empty() || result.arch.empty() || result.libc.empty() || result.home.empty() || result.target.empty()) {
      throw CommandError{"MachineProbeUnreadable"};
    }

    return result;
  }

  inline std::string assetName() const {
    return "telar-" + os + "-" + arch + (os == "linux" ? "-headless.tar.gz" : ".tar.gz");
  }
};

}
}

// Interface: machines/remote_shell.cppm
export {
namespace telar::runtime::cli::machine {

template <Allocator Memory>
launch::Output runScript(Memory &memory, std::string_view destination, std::string_view script, std::chrono::seconds timeout = probe_timeout) {
  return launch::captureBytes(ssh(memory, destination, "exec /bin/sh -s"), script, timeout);
}

inline std::string assign(std::string_view name, std::string_view value) {
  return std::string{name} + "=" + launch::quote(value) + "\n";
}

inline std::string whole(const launch::Output &output) {
  if (output.dropped != 0) {
    throw CommandError{"RemoteOutputTooLong"};
  }

  return output.out;
}

inline bool answeredYes() {
  std::string answer;
  if (!std::getline(std::cin, answer) || answer.size() > 16) {
    return false;
  }

  const auto text = config_receive::lower(trimmed(answer));
  return text == "y" || text == "yes";
}

}
}

// Interface: machines/agents.cppm
export {
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

// `std.fmt.parseInt(u32, part, 10) catch null`, as Zig reads a Node.js version.
inline std::optional<std::uint32_t> maybeVersion(std::string_view part) noexcept {
  try {
    return parseInt<std::uint32_t>(part);
  } catch (const std::invalid_argument &) {
    return std::nullopt;
  }
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
    const auto dot = text.find('.');
    const auto major = maybeVersion(text.substr(0, dot));
    const auto minor = dot == std::string_view::npos ? std::nullopt : maybeVersion(text.substr(dot + 1, text.find('.', dot + 1) - dot - 1));
    constexpr std::uint32_t required_major = 22;
    constexpr std::uint32_t required_minor = 19;
    if (!major || !minor || *major < required_major || (*major == required_major && *minor < required_minor)) {
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
}

// Interface: machines/config_sync.cppm
export {
namespace telar::runtime::cli::machine {

inline constexpr unsigned config_json_depth = 256;

struct SyncEntry {
  std::string_view name;
  enum class Format {
    text,
    json,
    toml,
    tree
  } format = Format::text;
  bool hooks = false;
};

inline std::vector<SyncEntry> entriesFor(std::string_view agent) {
  using enum SyncEntry::Format;
  if (agent == "claude") {
    return {{"settings.json", json, true}, {"CLAUDE.md"}, {"keybindings.json", json}, {"rules", tree}, {"skills", tree}, {"commands", tree}, {"agents", tree}, {"output-styles", tree}, {"themes", tree}};
  }

  if (agent == "codex") {
    return {{"config.toml", toml}, {"hooks.json", json, true}, {"AGENTS.md"}, {"AGENTS.override.md"}, {"rules", tree}, {"prompts", tree}};
  }

  if (agent == "pi") {
    return {{"settings.json", json}, {"keybindings.json", json}, {"AGENTS.md"}, {"SYSTEM.md"}, {"APPEND_SYSTEM.md"}, {"skills", tree}, {"prompts", tree}, {"themes", tree}, {"extensions", tree}};
  }

  if (agent == "opencode") {
    return {{"opencode.json", json}, {"opencode.jsonc", json}, {"tui.json", json}, {"AGENTS.md"}, {"agents", tree}, {"commands", tree}, {"modes", tree}, {"skills", tree}, {"themes", tree}, {"plugins", tree}};
  }

  return {{"cli-config.json", json}, {"hooks.json", json, true}, {"skills", tree}, {"agents", tree}};
}

inline std::string remoteRoot(std::string_view agent) {
  if (agent == "claude") {
    return ".claude";
  }

  if (agent == "codex") {
    return ".codex";
  }

  if (agent == "pi") {
    return ".pi/agent";
  }

  if (agent == "opencode") {
    return ".config/opencode";
  }

  return ".cursor";
}

inline std::string localRoot(std::string_view agent, const std::string &home) {
  const auto *variable = agent == "claude" ? "CLAUDE_CONFIG_DIR" : agent == "codex"  ? "CODEX_HOME"
                                                               : agent == "pi"       ? "PI_CODING_AGENT_DIR"
                                                               : agent == "opencode" ? "XDG_CONFIG_HOME"
                                                                                     : "CURSOR_CONFIG_DIR";
  const auto *override = std::getenv(variable);
  return override && *override ? std::string{override} + (agent == "opencode" ? "/opencode" : "") : home + "/" + remoteRoot(agent);
}

inline std::vector<std::string_view> commandTokens(std::string_view command) {
  constexpr std::string_view separators = " \t\n;&|()'\"=";
  std::vector<std::string_view> tokens;
  while (!command.empty()) {
    const auto start = command.find_first_not_of(separators);
    if (start == std::string_view::npos) {
      break;
    }

    command.remove_prefix(start);
    const auto end = command.find_first_of(separators);
    tokens.push_back(command.substr(0, end));
    if (end == std::string_view::npos) {
      break;
    }

    command.remove_prefix(end + 1);
  }

  return tokens;
}

inline std::optional<std::string> homePath(std::string_view token, const std::string &home) {
  for (const auto prefix : {"~/", "$HOME/", "${HOME}/"}) {
    if (token.starts_with(prefix)) {
      return home + "/" + std::string{token.substr(std::string_view{prefix}.size())};
    }
  }

  if (token.starts_with(home + "/")) {
    return std::string{token};
  }

  return std::nullopt;
}

template <Allocator Memory>
void commands(Memory &memory, JsonValue value, std::vector<std::string> &output, bool inside = false) {
  if (value.encoded().starts_with('{')) {
    value.eachMember([&](JsonValue key, JsonValue child) {
      String<Memory> name{AllocatorRef<char, Memory>{memory}};
      key.string(name);
      if (inside && name == "command" && child.encoded().starts_with('"')) {
        String<Memory> text{AllocatorRef<char, Memory>{memory}};
        child.string(text);
        output.emplace_back(text);
      }

      commands(memory, child, output, inside || name == "hooks" || name == "statusLine");
    });
  } else if (value.encoded().starts_with('[')) {
    value.eachElement([&](JsonValue child) { commands(memory, child, output, inside); });
  }
}

template <Allocator Memory>
class ConfigSync {
  struct File {
    std::string remote;
    std::string bytes;
    SyncEntry::Format format;
    std::optional<std::string> hooks;
    mode_t mode;
    std::optional<JsonNode<Memory>> json;
  };

  struct Root {
    std::string remote;
    std::string real;
  };

  Memory &memory_;
  std::string home_;
  std::string remote_home_;
  std::vector<Root> roots_;
  std::map<std::string, std::string> local_roots_;
  std::vector<File> files_;
  std::vector<std::string> left_;
  std::size_t total_ = 0;

  inline static bool below(std::string_view path, std::string_view root) {
    return path.starts_with(root) && path.size() > root.size() && path[root.size()] == '/';
  }

  inline bool inside(std::string_view remote, std::string_view real) const {
    for (const auto &root : roots_) {
      if (below(remote, root.remote)) {
        return real == root.real || below(real, root.real);
      }
    }

    return false;
  }

  inline bool staged(std::string_view path) const {
    return std::ranges::any_of(files_, [&](const File &file) { return file.remote == path; });
  }

  inline bool addRoot(const std::string &remote, const std::string &local) {
    std::error_code error;
    const auto real = std::filesystem::canonical(local, error);
    if (error) {
      return false;
    }

    roots_.push_back({remote, real.string()});
    return true;
  }

  inline static bool owned(std::string_view remote) {
    static constexpr auto paths = std::to_array<std::string_view>({"skills/telar", "skills/telar-coordinator", "extensions/telar.ts", "plugins/telar.ts"});
    return std::ranges::any_of(paths, [&](auto path) { return remote == path || below(remote, path); });
  }

  inline void addFile(const std::string &local, const std::string &remote, SyncEntry entry) {
    if (staged(remote)) {
      return;
    }

    std::error_code error;
    const auto real = std::filesystem::canonical(local, error).string();
    if (error) {
      return;
    }

    // Apply the same denylist to the original and canonical file names.
    if (!config_receive::acceptable(remote) || !safeLocal(local) || !safeLocal(real)) {
      left_.push_back(remote + ": never sent");
      return;
    }

    if (!inside(remote, real)) {
      left_.push_back(remote + ": leads outside its agent's directory, not sent");
      return;
    }

    FileDescriptor file{::open(real.c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)};
    struct stat state{};
    if (!file || ::fstat(file.get(), &state) != 0 || !S_ISREG(state.st_mode)) {
      return;
    }

    if (state.st_nlink > 1) {
      left_.push_back(remote + ": has another hard link, which could be any file; not sent");
      return;
    }

    if (state.st_size < 0 || static_cast<std::uint64_t>(state.st_size) > config_receive::max_file_bytes) {
      left_.push_back(remote + ": larger than 1024 KiB, not sent");
      return;
    }

    if (files_.size() == config_receive::max_files || total_ + static_cast<std::uint64_t>(state.st_size) > config_receive::max_total_bytes) {
      left_.push_back(remote + ": the sync is full, not sent");
      return;
    }

    std::string bytes;
    std::array<char, 16 * 1024> buffer;
    for (;;) {
      const auto count = ::read(file.get(), buffer.data(), buffer.size());
      if (count < 0 && errno == EINTR) {
        continue;
      }

      if (count < 0) {
        return;
      }

      if (count == 0) {
        break;
      }

      if (bytes.size() + static_cast<std::size_t>(count) > config_receive::max_file_bytes) {
        left_.push_back(remote + ": larger than 1024 KiB, not sent");
        return;
      }

      bytes.append(buffer.data(), static_cast<std::size_t>(count));
    }

    total_ += bytes.size();
    files_.push_back({remote, std::move(bytes), entry.format, entry.hooks ? std::optional<std::string>{entry.name} : std::nullopt, static_cast<mode_t>((state.st_mode & 0111) != 0 ? 0755 : 0644), std::nullopt});
  }

  inline static bool safeLocal(const std::string &path) {
    // The canonical path can have arbitrary non-agent ancestors; keep only
    // their names for the denylist, then reuse acceptable's leaf checks.
    auto tail = std::string_view{path};
    static constexpr auto directories = std::to_array<std::string_view>({".ssh", ".gnupg", ".aws", ".kube", ".docker", "keychains", "gcloud", ".password-store"});
    for (;;) {
      const auto slash = tail.find('/');
      const auto component = filter::lower(tail.substr(0, slash));
      if (std::ranges::find(directories, component) != directories.end()) {
        return false;
      }

      if (slash == std::string_view::npos) {
        break;
      }

      tail.remove_prefix(slash + 1);
    }

    return config_receive::acceptable(".claude/" + std::filesystem::path{path}.filename().string());
  }

  inline void addTree(const std::string &local, const std::string &remote, unsigned depth) {
    constexpr unsigned max_depth = 16;
    if (owned(remote)) {
      return;
    }

    if (depth > max_depth) {
      left_.push_back(remote + "/: deeper than 16 directories, not sent");
      return;
    }

    std::error_code error;
    const auto real = std::filesystem::canonical(local, error);
    if (error) {
      return;
    }

    if (!inside(remote, real.string())) {
      left_.push_back(remote + "/: leads outside its agent's directory, not sent");
      return;
    }

    std::filesystem::directory_iterator iterator{local, error};
    if (error) {
      return;
    }

    for (const auto &entry : iterator) {
      const auto name = entry.path().filename().string();
      if (name.empty() || name.front() == '.') {
        continue;
      }

      const auto target = remote + "/" + name;
      if (owned(target)) {
        continue;
      }

      if (entry.is_directory(error) && !error) {
        addTree(entry.path().string(), target, depth + 1);
      } else if (entry.is_regular_file(error) && !error) {
        addFile(entry.path().string(), target, {name});
      }

      error.clear();
    }
  }

  inline bool keep(std::size_t index, std::string bytes) {
    if (const auto found = filter::findSecret(bytes)) {
      left_.push_back(files_[index].remote + ": held back, line " + std::to_string(found->first) + " holds what looks like " + std::string{found->second} + "; review it and sync again");
      return false;
    }

    files_[index].bytes = std::move(bytes);
    return true;
  }

  inline void bringCommands(const JsonValue &value) {
    std::vector<std::string> found;
    commands(memory_, value, found);
    for (const auto &command : found) {
      for (const auto token : commandTokens(command)) {
        const auto local = homePath(token, home_);
        if (!local) {
          continue;
        }

        for (const auto &[agent, root] : local_roots_) {
          if (below(*local, root)) {
            addFile(*local, remoteRoot(agent) + local->substr(root.size()), {*local});
          }
        }
      }
    }
  }

  inline void transform(const std::string &program) {
    for (std::size_t index = 0; index < files_.size();) {
      const auto original = files_[index].bytes;
      const auto path = files_[index].remote;
      const auto hooks = files_[index].hooks;
      std::vector<std::string> dropped;
      bool retain = true;
      if (files_[index].format == SyncEntry::Format::json) {
        try {
          const auto plain = filter::stripJsonc(original);
          // Validate duplicates and UTF-8 before traversing JsonValue.
          static_cast<void>(JsonNode<Memory>::parse(memory_, plain));
          String<Memory> filtered{AllocatorRef<char, Memory>{memory_}};
          filter::json(memory_, JsonValue::parse(plain, config_json_depth), filtered, dropped);
          bringCommands(JsonValue::parse(filtered, config_json_depth));
          auto node = JsonNode<Memory>::parse(memory_, filtered);
          auto formatted = node.format();
          // Rewriting encoded strings keeps JSON escapes intact, including
          // a remote home containing quotes or backslashes.
          const auto rewritten = rewriteJson(JsonValue::parse(formatted, config_json_depth));
          node = JsonNode<Memory>::parse(memory_, rewritten);
          if (hooks) {
            const auto provider = *hooks == "claude" ? AgentProvider::claude : *hooks == "codex" ? AgentProvider::codex
                                                                                                 : AgentProvider::cursor;
            if (node.kind() != JsonKind::object) {
              throw CommandError{"InvalidSettings"};
            }

            integration::HookSettings settings{memory_, integration::Provider::describe(provider), program};
            settings.install(node);
          }

          files_[index].json = std::move(node);
        } catch (const CommandError &error) {
          if (std::string_view{error.what()} != "UnterminatedComment") {
            throw;
          }

          left_.push_back(path + ": not valid JSON here, not sent");
          retain = false;
        } catch (const std::bad_alloc &) {
          throw;
        } catch (const std::exception &) {
          left_.push_back(path + ": not valid JSON here, not sent");
          retain = false;
        }
      } else {
        const auto filtered = files_[index].format == SyncEntry::Format::toml ? filter::toml(original, dropped) : original;
        retain = keep(index, filter::rewriteHome(filtered, home_, remote_home_));
      }

      if (!dropped.empty()) {
        std::string names;
        for (const auto &name : dropped) {
          if (!names.empty()) {
            names += ", ";
          }

          names += name;
        }

        left_.push_back(path + ": left out " + names);
      }

      if (retain) {
        ++index;
      } else {
        files_.erase(files_.begin() + static_cast<std::ptrdiff_t>(index));
      }
    }
  }

  inline String<Memory> rewriteJson(JsonValue value) {
    String<Memory> output{AllocatorRef<char, Memory>{memory_}};
    const auto encoded = value.encoded();
    if (encoded.starts_with('"')) {
      String<Memory> text{AllocatorRef<char, Memory>{memory_}};
      value.string(text);
      appendJsonText(output, filter::rewriteHome(text, home_, remote_home_), JsonEscapes::standard);
    } else if (encoded.starts_with('{')) {
      output += '{';
      bool first = true;
      value.eachMember([&](JsonValue key, JsonValue child) {
        if (!first) {
          output += ',';
        }

        first = false;
        output += key.encoded();
        output += ':';
        output += rewriteJson(child);
      });
      output += '}';
    } else if (encoded.starts_with('[')) {
      output += '[';
      bool first = true;
      value.eachElement([&](JsonValue child) { if (!first) { output += ','; } first = false; output += rewriteJson(child); });
      output += ']';
    } else {
      output += encoded;
    }

    return output;
  }

  inline std::vector<std::string> paths(std::string_view command) const {
    std::vector<std::string> result;
    for (const auto token : commandTokens(command)) {
      if (token.starts_with('/')) {
        result.emplace_back(token);
      } else if (const auto expanded = homePath(token, remote_home_)) {
        result.push_back(*expanded);
      }
    }

    return result;
  }

  inline std::set<std::string> queryPaths(const std::string &destination) {
    std::vector<std::string> asked;
    for (const auto &file : files_) {
      if (!file.json) {
        continue;
      }

      std::vector<std::string> found;
      const auto formatted = file.json->format();
      commands(memory_, JsonValue::parse(formatted, config_json_depth), found);
      for (const auto &command : found) {
        for (const auto &path : paths(command)) {
          if (!path.contains('\n') && path != "TELAR_PATHS") {
            asked.push_back(path);
          }
        }
      }
    }

    std::set<std::string> result;
    if (asked.empty()) {
      return result;
    }

    std::string script = "while IFS= read -r path; do if [ -e \"$path\" ]; then printf '%s\\n' \"$path\"; fi; done <<'TELAR_PATHS'\n";
    for (const auto &path : asked) {
      script += path + "\n";
    }

    script += "TELAR_PATHS\n";
    const auto output = runScript(memory_, destination, script);
    if (output.status != 0) {
      throw CommandError{"MachinePathsUnreadable"};
    }

    auto lines = std::string_view{output.out};
    if (output.dropped != 0) {
      throw CommandError{"RemoteOutputTooLong"};
    }

    while (!lines.empty()) {
      const auto end = lines.find('\n');
      if (const auto line = lines.substr(0, end); !line.empty()) {
        result.emplace(line);
      }

      if (end == std::string_view::npos) {
        break;
      }

      lines.remove_prefix(end + 1);
    }

    return result;
  }

  inline bool commandRuns(std::string_view command, const std::set<std::string> &existing) const {
    if (command.ends_with(" hook claude") || command.ends_with(" hook codex") || command.ends_with(" hook cursor")) {
      return true;
    }

    for (const auto &path : paths(command)) {
      if (existing.contains(path) || (below(path, remote_home_) && staged(std::string_view{path}.substr(remote_home_.size() + 1)))) {
        continue;
      }

      return false;
    }

    return true;
  }

  inline bool keepCommands(JsonNode<Memory> &node, const std::set<std::string> &existing, const std::string &path) {
    if (node.kind() == JsonKind::object) {
      if (const auto *command = node.find("command"); command && command->kind() == JsonKind::string && !commandRuns(command->text(), existing)) {
        left_.push_back(path + ": left out `" + std::string{command->text()} + "`, whose program is not there");
        return false;
      }
    }

    if (node.kind() == JsonKind::array || node.kind() == JsonKind::object) {
      const bool had_items = !node.children().empty();
      for (std::size_t index = 0; index < node.children().size();) {
        auto &child = node.children()[index];
        const bool container = child.kind() == JsonKind::object || child.kind() == JsonKind::array;
        const bool recurse = container && (node.kind() == JsonKind::array || !child.children().empty());
        if (recurse && !keepCommands(child, existing, path)) {
          node.erase(index);
        } else {
          ++index;
        }
      }

      return node.kind() == JsonKind::array ? !had_items || !node.children().empty() : !node.children().empty();
    }

    return true;
  }

public:
  inline ConfigSync(Memory &memory, std::string home, std::string remote_home)
      : memory_(memory),
        home_(std::move(home)),
        remote_home_(std::move(remote_home)) {}

  inline void run(SetupReport &report, const std::string &destination, const Platform &platform, const std::set<std::string> &wanted) {
    for (const auto name : agent_names) {
      const std::string agent{name};
      if (!wanted.contains(agent)) {
        continue;
      }

      const auto root = localRoot(agent, home_);
      local_roots_[agent] = root;
      const auto remote = remoteRoot(agent);
      if (!addRoot(remote, root)) {
        continue;
      }

      for (const auto entry : entriesFor(agent)) {
        const auto local_path = root + "/" + std::string{entry.name};
        const auto remote_path = remote + "/" + std::string{entry.name};
        if (entry.format == SyncEntry::Format::tree) {
          addTree(local_path, remote_path, 0);
        } else {
          auto source = entry;
          if (source.hooks) {
            source.name = agent;
          }

          addFile(local_path, remote_path, source);
        }
      }
    }

    if (wanted.contains("codex") || wanted.contains("opencode") || wanted.contains("cursor")) {
      constexpr std::string_view shared = ".agents/skills";
      const auto local = home_ + "/" + std::string{shared};
      if (addRoot(std::string{shared}, local)) {
        addTree(local, std::string{shared}, 0);
      }
    }

    transform(platform.target);
    const auto existing = queryPaths(destination);
    for (auto &file : files_) {
      if (!file.json || file.json->kind() != JsonKind::object) {
        continue;
      }

      if (auto *status = file.json->find("statusLine"); status && !keepCommands(*status, existing, file.remote)) {
        file.json->remove("statusLine");
      }

      if (auto *hooks = file.json->find("hooks")) {
        keepCommands(*hooks, existing, file.remote);
      }
    }

    std::string stream = "telar-config 1\n";
    for (std::size_t index = 0; index < files_.size();) {
      auto &file = files_[index];
      if (file.json) {
        const auto formatted = file.json->format();
        if (!keep(index, std::string{formatted})) {
          files_.erase(files_.begin() + static_cast<std::ptrdiff_t>(index));
          continue;
        }
      }

      stream += "file " + std::string{file.mode == 0755 ? "755" : "644"} + " " + std::to_string(file.bytes.size()) + " " + file.remote + "\n" + file.bytes + "\n";
      ++index;
    }

    stream += "end\n";
    constexpr auto send_timeout = std::chrono::seconds{600};
    const auto output = launch::captureBytes(ssh(memory_, destination, platform.target + " machine receive-config"), stream, send_timeout);
    if (output.status != 0) {
      report.end(Step::configuration, Status::failed, "the machine refused the sync: " + std::string{output.errorLine()});
      return;
    }

    const auto contents = whole(output);
    auto lines = std::string_view{contents};
    std::size_t written = 0;
    while (!lines.empty()) {
      const auto end = lines.find('\n');
      const auto line = lines.substr(0, end);
      if (line.starts_with("written ")) {
        ++written;
        report.note(Step::configuration, std::string{line});
      } else if (line.starts_with("refused ")) {
        report.note(Step::configuration, "left alone there: " + std::string{line.substr(8)});
      }

      if (end == std::string_view::npos) {
        break;
      }

      lines.remove_prefix(end + 1);
    }

    for (const auto &line : left_) {
      report.note(Step::configuration, line);
    }

    report.end(Step::configuration, written != 0 ? Status::changed : Status::ok, std::to_string(written) + " of " + std::to_string(files_.size()) + " files written; credentials, sessions and history stay here");
  }
};

template <Allocator Memory>
void syncConfig(Memory &memory, SetupReport &report, const std::string &destination, const Platform &platform, const std::set<std::string> &wanted) {
  if (wanted.empty()) {
    report.end(Step::configuration, Status::skipped, "no agent here to take configuration from");
    return;
  }

  try {
    const auto *home = std::getenv("HOME");
    if (!home) {
      throw CommandError{"HomeUnavailable"};
    }

    ConfigSync sync{memory, std::string{home}, platform.home};
    sync.run(report, destination, platform, wanted);
  } catch (const std::exception &error) {
    report.end(Step::configuration, Status::failed, std::string{error.what()} + "; nothing more was written there");
  }
}

}
}

// Interface: machines/logins.cppm
export {
namespace telar::runtime::cli::machine {

struct LoginPlan {
  std::string title;
  std::vector<std::string> arguments;
  std::optional<std::string> environment;
  std::optional<std::string> keys;
  bool link = true;
  std::vector<std::string_view> hosts;
  std::optional<std::string> code_marker;
  std::optional<std::string> paste;
  std::string instructions;
};

inline std::optional<LoginPlan> planFor(std::string_view agent, const std::optional<std::string> &provider) {
  if (agent == "claude") {
    return LoginPlan{.title = "Log in to Claude Code", .arguments = {"auth", "login"}, .hosts = {"claude.com", "claude.ai", "platform.claude.com"}, .paste = "the code the browser shows", .instructions = "open the page, sign in, and paste the code it shows into this terminal"};
  }

  if (agent == "codex") {
    return LoginPlan{.title = "Log in to Codex", .arguments = {"login", "--device-auth"}, .hosts = {"auth.openai.com"}, .code_marker = "one-time code", .instructions = "open the page, sign in and enter the code"};
  }

  if (agent == "cursor") {
    return LoginPlan{.title = "Log in to Cursor Agent", .arguments = {"login"}, .environment = "NO_OPEN_BROWSER=1", .hosts = {"cursor.com"}, .instructions = "open the page and sign in"};
  }

  if (agent == "pi" && provider) {
    return LoginPlan{.title = "Log in to Pi", .keys = "/login", .link = false, .instructions = "choose the provider in the Pi pane there"};
  }

  if (agent == "opencode" && provider == "openai") {
    return LoginPlan{.title = "Log in to OpenCode", .arguments = {"auth", "login", "-p", "openai", "-m", "ChatGPT Pro/Plus (headless)"}, .hosts = {"auth.openai.com"}, .code_marker = "Enter code:", .instructions = "open the page, sign in and enter the code"};
  }

  return std::nullopt;
}

struct LoginPane {
  std::uint64_t workspace = 0;
  std::uint64_t tab = 0;
  std::uint64_t pane = 0;
  bool operator==(const LoginPane &) const = default;
};

struct LoginLink {
  std::string url;
  std::optional<std::string> code;
};

inline std::optional<LoginLink> findLoginLink(std::string_view text, const LoginPlan &plan) {
  std::string_view url;
  for (std::size_t start = 0;;) {
    const auto at = text.find("https://", start);
    if (at == std::string_view::npos) {
      return std::nullopt;
    }

    start = at + 1;
    auto end = at;
    while (end < text.size() && static_cast<unsigned char>(text[end]) > ' ' && static_cast<unsigned char>(text[end]) < 0x7f && !std::string_view{"\"'<>`"}.contains(text[end])) {
      ++end;
    }

    auto candidate = text.substr(at, end - at);
    while (candidate.size() > notification_link_scheme.size() && std::string_view{".,;:)]}"}.contains(candidate.back())) {
      candidate.remove_suffix(1);
    }

    try {
      if (candidate.size() > max_notification_link_bytes) {
        continue;
      }

      BodySchema<NotificationBody>::validate({.link = candidate});
    } catch (const std::exception &) {
      continue;
    }

    const auto host = filter::lower(notificationLinkHost(candidate));
    if (std::ranges::find(plan.hosts, host) != plan.hosts.end()) {
      url = candidate;
      break;
    }
  }

  LoginLink result{.url = std::string{url}};
  if (!plan.code_marker) {
    return result;
  }

  const auto marker = text.find(*plan.code_marker);
  if (marker == std::string_view::npos) {
    return result;
  }

  auto lines = text.substr(marker + plan.code_marker->size());
  for (;;) {
    const auto end = lines.find('\n');
    const auto line = filter::trim(lines.substr(0, end), " \t\r");
    const auto word = line.substr(0, line.find_first_of(" \t\r"));
    if (!word.empty() && !word.starts_with('(')) {
      result.code = word;
      return result;
    }

    if (end == std::string_view::npos) {
      return result;
    }

    lines.remove_prefix(end + 1);
  }
}

template <Allocator Memory>
class Logins {
  Memory &memory_;
  SetupReport &report_;
  const MachineProfile &profile_;
  const Platform &platform_;
  bool interactive_;
  static constexpr auto status_timeout = std::chrono::seconds{30};
  static constexpr auto link_timeout = std::chrono::seconds{60};
  static constexpr auto finish_timeout = std::chrono::minutes{15};
  static constexpr auto poll_interval = std::chrono::milliseconds{500};
  static constexpr auto status_interval = std::chrono::seconds{3};
  static constexpr std::string_view records = "$HOME/.local/state/telar/setup-logins";

  inline static JsonValue required(JsonValue value, std::string_view name) {
    const auto field = value.field(name);
    if (!field) {
      throw CommandError{"LoginPaneUnreadable"};
    }

    return *field;
  }

  inline static std::uint64_t number(JsonValue value) {
    const auto text = value.encoded();
    std::uint64_t result = 0;
    const auto parsed = std::from_chars(text.data(), text.data() + text.size(), result);
    if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) {
      throw CommandError{"LoginPaneUnreadable"};
    }

    return result;
  }

  inline std::string string(JsonValue value) {
    String<Memory> result{AllocatorRef<char, Memory>{memory_}};
    value.string(result);
    return std::string{result};
  }

  inline static LoginPane pane(JsonValue value) {
    return {number(required(value, "workspace_id")), number(required(value, "tab_id")), number(required(value, "pane_id"))};
  }

  inline std::string capture(const std::vector<std::string> &words, std::optional<std::string_view> input = std::nullopt) {
    // The same encoded command, length limit included, as every dispatch.
    const auto command = remoteCommand(profile_, words);
    const auto output = input ? launch::captureBytes(ssh(memory_, profile_.destination(), command), *input, status_timeout) : launch::capture(ssh(memory_, profile_.destination(), command), -1, status_timeout);
    std::fwrite(output.err.data(), 1, output.err.size(), stderr);
    if (output.status != 0) {
      throw CommandError{"MachineCommandFailed"};
    }

    return whole(output);
  }

  inline launch::Output script(std::string_view bytes) {
    return runScript(memory_, profile_.destination(), bytes, status_timeout);
  }

  inline std::optional<std::string> command(const std::vector<std::string> &words, bool missing_pane) {
    std::string bytes = "exec " + launch::quote(profile_.program().value_or("telar"));
    for (const auto &word : words) {
      bytes += " " + launch::quote(word);
    }

    bytes += '\n';
    const auto output = script(bytes);
    auto diagnostic = std::string_view{output.err};
    while (diagnostic.ends_with('\n') || diagnostic.ends_with('\r')) {
      diagnostic.remove_suffix(1);
    }

    const bool missing = output.out.empty() && (missing_pane ? output.status == 2 && diagnostic == "telar pane: pane not found or its generation is stale" : output.status == 1 && (diagnostic == "telar tab: tab not found" || diagnostic == "telar tab: workspace not found"));
    if (missing) {
      return std::nullopt;
    }

    std::fwrite(output.err.data(), 1, output.err.size(), stderr);
    if (output.status == launch::ssh_failure) {
      throw CommandError{"SshFailed"};
    }

    if (output.status != 0) {
      throw CommandError{"MachineCommandFailed"};
    }

    return whole(output);
  }

  inline std::string recordPath(const std::string &agent) {
    return std::string{records} + "/" + agent;
  }

  inline void forget(const std::string &agent) {
    if (script("rm -f \"" + recordPath(agent) + "\"\n").status != 0) {
      throw CommandError{"LoginRecordUnwritable"};
    }
  }

  inline void remember(const std::string &agent, LoginPane pane) {
    const auto bytes = "umask 077 && mkdir -p \"" + std::string{records} + "\" && printf '%s\\n' '" + std::to_string(pane.workspace) + " " + std::to_string(pane.tab) + " " + std::to_string(pane.pane) + "' > \"" + recordPath(agent) + "\"\n";
    if (script(bytes).status != 0) {
      throw CommandError{"LoginRecordUnwritable"};
    }
  }

  inline std::optional<LoginPane> find(const std::string &agent, const std::string &title) {
    const auto output = script("cat \"" + recordPath(agent) + "\" 2>/dev/null || true\n");
    if (output.status != 0) {
      throw CommandError{"LoginRecordUnreadable"};
    }

    std::istringstream input{whole(output)};
    LoginPane noted;
    std::string extra;
    if (!(input >> noted.workspace >> noted.tab >> noted.pane) || input >> extra) {
      return std::nullopt;
    }

    const auto workspaces = capture({"workspace", "list", "--json"});
    bool named = false;
    JsonValue::parse(workspaces).eachElement([&](JsonValue value) {
      if (number(required(value, "workspace_id")) == noted.workspace && string(required(value, "name")) == title) {
        named = true;
      }
    });
    if (!named) {
      forget(agent);
      return std::nullopt;
    }

    const auto tab = command({"tab", "get", std::to_string(noted.tab), "--workspace", std::to_string(noted.workspace), "--json"}, false);
    if (tab) {
      const auto parsed = JsonValue::parse(*tab);
      if (number(required(parsed, "workspace_id")) != noted.workspace || number(required(parsed, "tab_id")) != noted.tab) {
        throw CommandError{"LoginPaneUnreadable"};
      }

      bool found = false;
      required(parsed, "panes").eachElement([&](JsonValue value) { found = found || number(required(value, "pane_id")) == noted.pane; });
      if (found) {
        return noted;
      }
    }

    forget(agent);
    return std::nullopt;
  }

  inline void closeTab(LoginPane pane) {
    const auto output = command({"tab", "close", std::to_string(pane.tab), "--workspace", std::to_string(pane.workspace), "--json"}, false);
    if (!output) {
      return;
    }

    const auto value = JsonValue::parse(*output);
    if (number(required(value, "workspace_id")) != pane.workspace || number(required(value, "tab_id")) != pane.tab || required(value, "closed").encoded() != "true") {
      throw CommandError{"LoginPaneUnreadable"};
    }
  }

  inline void close(const std::string &agent, LoginPane pane, const LoginPlan &plan) {
    const auto current = find(agent, plan.title);
    if (!current || *current != pane) {
      return;
    }

    closeTab(pane);
    forget(agent);
  }

  inline LoginPane open(const std::string &agent, const std::string &path, const LoginPlan &plan) {
    std::vector<std::string> words{"workspace", "create", "--directory", platform_.home, "--name", plan.title, "--columns", "1024", "--json", "--"};
    if (plan.environment) {
      words.push_back("/usr/bin/env");
      words.push_back(*plan.environment);
    }

    words.push_back(path);
    words.insert(words.end(), plan.arguments.begin(), plan.arguments.end());
    const auto output = capture(words);
    LoginPane created;
    try {
      created = pane(JsonValue::parse(output));
    } catch (const std::exception &) {
      throw CommandError{"LoginPaneUnreadable"};
    }

    try {
      remember(agent, created);
    } catch (...) {
      try {
        closeTab(created);
      } catch (const std::exception &) {
      }

      throw;
    }

    return created;
  }

  inline std::optional<std::string> provider(const std::string &agent) {
    if (agent != "pi" && agent != "opencode") {
      return std::nullopt;
    }

    const auto *home = std::getenv("HOME");
    if (!home) {
      return std::nullopt;
    }

    const auto root = localRoot(agent, home);
    const auto filenames = agent == "pi" ? std::vector<std::string>{"settings.json"} : std::vector<std::string>{"opencode.json", "opencode.jsonc"};
    for (const auto &name : filenames) {
      try {
        String<Memory> path{root + "/" + name, AllocatorRef<char, Memory>{memory_}};
        const auto bytes = integration::read(memory_, path, launch::output_limit);
        if (!bytes) {
          continue;
        }

        const auto plain = filter::stripJsonc(*bytes);
        const auto parsed = JsonValue::parse(plain);
        if (!parsed.encoded().starts_with('{')) {
          return std::nullopt;
        }

        const auto field = parsed.field(agent == "pi" ? "defaultProvider" : "model");
        if (!field || !field->encoded().starts_with('"')) {
          continue;
        }

        const auto value = string(*field);
        if (agent == "pi") {
          return value;
        }

        const auto slash = value.find('/');
        if (slash != std::string::npos) {
          return value.substr(0, slash);
        }
      } catch (const std::exception &) {
      }
    }

    return std::nullopt;
  }

  inline bool loggedIn(const std::string &agent, const std::string &path, const std::optional<std::string> &provider) {
    std::string check;
    if (agent == "claude") {
      check = "\"$agent\" auth status >/dev/null 2>&1";
    } else if (agent == "codex") {
      check = "\"$agent\" login status >/dev/null 2>&1";
    } else if (agent == "cursor") {
      check = "\"$agent\" status --format json 2>/dev/null | grep -Eq '\"status\": *\"authenticated\"|\"isAuthenticated\": *true'";
    } else if (agent == "pi") {
      check = "[ -n \"$provider\" ] && \"$agent\" auth check --provider \"$provider\" --no-refresh >/dev/null 2>&1";
    } else {
      check = "[ -n \"$provider\" ] && \"$agent\" auth list 2>/dev/null | grep -qi -- \"$provider\"";
    }

    const auto output = script(assign("agent", path) + assign("provider", provider.value_or("")) + check + "\n");
    if (output.status == launch::ssh_failure) {
      throw CommandError{"SshFailed"};
    }

    return output.status == 0;
  }

  struct Read {
    std::optional<int> exit_code;
    std::string text;
  };

  inline std::optional<Read> read(LoginPane pane) {
    const auto output = command({"pane", "read", std::to_string(pane.pane), "--lines", "80", "--json"}, true);
    if (!output) {
      return std::nullopt;
    }

    try {
      const auto value = JsonValue::parse(*output);
      if (number(required(value, "pane_id")) != pane.pane) {
        throw CommandError{"LoginPaneUnreadable"};
      }

      const auto exit = required(value, "exit_code").encoded();
      std::optional<int> code;
      if (exit != "null") {
        int parsed = 0;
        const auto result = std::from_chars(exit.data(), exit.data() + exit.size(), parsed);
        if (result.ec != std::errc{} || result.ptr != exit.data() + exit.size()) {
          throw CommandError{"LoginPaneUnreadable"};
        }

        code = parsed;
      }

      return Read{.exit_code = code, .text = string(required(value, "text"))};
    } catch (const std::exception &) {
      throw CommandError{"LoginPaneUnreadable"};
    }
  }

  inline std::optional<MachineLogin> ended(const std::string &agent, const std::string &path, const std::optional<std::string> &provider, std::optional<Read> read, LoginPane pane) {
    if (read && !read->exit_code) {
      return std::nullopt;
    }

    const auto logged_in = loggedIn(agent, path, provider);
    if (logged_in && (!read || read->exit_code == 0)) {
      return MachineLogin::done;
    }

    if (read && read->exit_code) {
      report_.note(Step::logins, agent + ": login command exited with " + std::to_string(*read->exit_code) + "; status is " + (logged_in ? "logged in" : "not logged in") + ". Read its diagnostic with pane read " + std::to_string(pane.pane) + " --json on " + std::string{profile_.label()} + ", then retry setup");
    } else {
      report_.note(Step::logins, agent + ": login pane disappeared before authentication completed; retry setup");
    }

    return MachineLogin::failed;
  }

  inline bool announce(const LoginPlan &plan, const LoginLink &found) {
    std::string body = "on " + std::string{profile_.label()} + ": " + plan.instructions;
    if (found.code) {
      body += ". Code: " + *found.code;
    }

    if (body.size() > max_notification_message_bytes && found.code) {
      body = "Code: " + *found.code + ", on " + std::string{profile_.label()} + ": " + plan.instructions;
    }

    try {
      const RuntimePaths paths{memory_, ServerOptions{}, ProcessEnvironment{}};
      ControlSession session{memory_, paths.socket.c_str()};
      session.receiveTimeout(static_cast<unsigned>(status_timeout.count()));
      const auto result = session.template exchange<NotificationShown>(ShowNotification{.notification = {.duration_ms = max_notification_duration_ms, .title = utf8Prefix(plan.title, max_notification_title_bytes), .message = utf8Prefix(body, max_notification_message_bytes), .link = found.url}});
      return result.delivered_clients != 0;
    } catch (const std::exception &) {
      return false;
    }
  }

  inline void send(LoginPane pane, std::string_view text) {
    capture({"pane", "send-keys", std::to_string(pane.pane), "--stdin", "--enter"}, text);
  }

  struct Request {
    std::string agent;
    std::string path;
    std::optional<std::string> provider;
    LoginPlan plan;
  };

  inline MachineLogin loginOne(const Request &request) {
    const auto &agent = request.agent;
    const auto &path = request.path;
    const auto &provider = request.provider;
    const auto &plan = request.plan;
    const auto existing = find(agent, plan.title);
    const auto pane = existing ? *existing : open(agent, path, plan);
    try {
      if (existing) {
        report_.progress(plan.title + " on " + std::string{profile_.label()} + ": the login setup started before is still open there");
      } else if (plan.keys) {
        send(pane, *plan.keys);
      }

      if (plan.link) {
        const auto deadline = std::chrono::steady_clock::now() + link_timeout;
        std::optional<LoginLink> found;
        while (std::chrono::steady_clock::now() < deadline) {
          const auto value = read(pane);
          if (const auto result = ended(agent, path, provider, value, pane)) {
            close(agent, pane, plan);
            return *result;
          }

          found = findLoginLink(value->text, plan);
          if (found && (!plan.code_marker || found->code)) {
            break;
          }

          found.reset();
          std::this_thread::sleep_for(poll_interval);
        }

        if (!found) {
          report_.progress(agent + ": no login link appeared in its pane on " + std::string{profile_.label()} + "; finish it there");
          return MachineLogin::pending;
        }

        report_.progress(plan.title + " on " + std::string{profile_.label()} + ": " + found->url);
        if (found->code) {
          report_.progress("one-time code: " + *found->code);
        }

        if (!announce(plan, *found)) {
          report_.progress("no window here took the notification; open the link above");
        }
      } else {
        announce(plan, {});
        report_.progress(plan.title + " on " + std::string{profile_.label()} + ": " + plan.instructions);
      }

      if (!interactive_) {
        if (const auto result = ended(agent, path, provider, read(pane), pane)) {
          close(agent, pane, plan);
          return *result;
        }

        return MachineLogin::pending;
      }

      if (plan.paste) {
        std::printf("Paste %s for %s (Enter to finish in the pane instead): ", plan.paste->c_str(), agent.c_str());
        std::fflush(stdout);
        std::string answer;
        if (std::getline(std::cin, answer) && answer.size() < max_notification_message_bytes * 8) {
          const auto text = filter::trim(answer, " \r\t");
          if (!text.empty()) {
            send(pane, text);
          }
        }
      }

      const auto deadline = std::chrono::steady_clock::now() + finish_timeout;
      auto status_at = std::chrono::steady_clock::now();
      while (std::chrono::steady_clock::now() < deadline) {
        if (const auto result = ended(agent, path, provider, read(pane), pane)) {
          close(agent, pane, plan);
          return *result;
        }

        if (std::chrono::steady_clock::now() >= status_at) {
          if (loggedIn(agent, path, provider)) {
            close(agent, pane, plan);
            return MachineLogin::done;
          }

          status_at = std::chrono::steady_clock::now() + status_interval;
        }

        std::this_thread::sleep_for(poll_interval);
      }

      report_.note(Step::logins, agent + ": authentication did not complete before the login timeout; retry setup");
      close(agent, pane, plan);
      return MachineLogin::failed;
    } catch (...) {
      try {
        close(agent, pane, plan);
      } catch (const std::exception &) {
      }

      throw;
    }
  }

public:
  inline Logins(Memory &memory, SetupReport &report, const MachineProfile &profile, const Platform &platform, bool interactive)
      : memory_(memory),
        report_(report),
        profile_(profile),
        platform_(platform),
        interactive_(interactive) {}

  inline void run(const std::set<std::string> &wanted, const std::string &profiles_path) {
    std::map<std::string, MachineLogin> results;
    bool started = false;
    for (const auto name : agent_names) {
      const std::string agent{name};
      if (!wanted.contains(agent) || !platform_.agents.contains(agent)) {
        continue;
      }

      const auto &path = platform_.agents.at(agent);
      const auto selected = provider(agent);
      bool logged_in = false;
      try {
        logged_in = loggedIn(agent, path, selected);
      } catch (const std::exception &error) {
        report_.note(Step::logins, agent + ": its login status could not be read there: " + error.what());
        results[agent] = MachineLogin::failed;
        continue;
      }

      const auto plan = planFor(agent, selected);
      if (logged_in) {
        try {
          if (plan) {
            if (const auto pane = find(agent, plan->title)) {
              close(agent, *pane, *plan);
            }
          }
        } catch (const std::exception &error) {
          report_.note(Step::logins, agent + ": its login cleanup failed: " + error.what());
          results[agent] = MachineLogin::failed;
          continue;
        }

        results[agent] = MachineLogin::done;
        report_.note(Step::logins, agent + ": logged in");
      } else if (!plan) {
        report_.note(Step::logins, agent + ": log in there yourself; setup has no browser login for " + selected.value_or("its provider"));
      } else {
        started = true;
        try {
          results[agent] = loginOne({agent, path, selected, *plan});
        } catch (const std::exception &error) {
          report_.note(Step::logins, agent + ": " + error.what());
          results[agent] = MachineLogin::failed;
        }

        if (results[agent] != MachineLogin::failed) {
          report_.note(Step::logins, agent + ": " + std::string{machine_login_names[static_cast<std::size_t>(results[agent])]});
        }
      }
    }

    try {
      if (!results.empty()) {
        update(memory_, profiles_path, [&](MachineProfiles &profiles) {
          for (const auto &[agent, result] : results) {
            const auto found = std::ranges::find(machine_agent_names, agent);
            profiles.recordLogin(profile_.label(), static_cast<MachineAgent>(found - machine_agent_names.begin()), result);
          }
        });
      }
    } catch (const std::exception &error) {
      const auto *text = describe(error.what());
      report_.note(Step::logins, std::string{"machines.json keeps the logins it had: "} + (text ? text : error.what()));
    }

    const bool failed = std::ranges::any_of(results, [](const auto &entry) { return entry.second == MachineLogin::failed; });
    const bool pending = std::ranges::any_of(results, [](const auto &entry) { return entry.second == MachineLogin::pending; });
    const auto status = failed ? Status::failed : results.empty() ? Status::skipped
                                              : pending           ? Status::pending
                                              : started           ? Status::changed
                                                                  : Status::ok;
    report_.end(Step::logins, status, failed ? "a login failed; see the notes" : results.empty() ? "no agent there to log in"
                                                                             : pending           ? "a login waits for you; run setup again to see it done"
                                                                             : started           ? "every started login finished"
                                                                                                 : "every agent there is logged in");
  }
};

}
}

// Interface: machines/setup.cppm
export {
namespace telar::runtime::cli::machine {

struct Target {
  std::string label;
  std::string destination;
  std::optional<MachineProfile> saved;
};

inline Target resolve(const MachineProfiles &profiles, const MachineOptions &options) {
  for (const auto &profile : profiles.rows()) {
    if (profile.label() == options.label || profile.destination() == options.label) {
      return {.label = std::string{profile.label()}, .destination = std::string{profile.destination()}, .saved = profile};
    }
  }

  MachineFieldRules::profileDestination(options.label);
  auto host = options.label;
  if (host.starts_with("ssh://")) {
    host.remove_prefix(std::string_view{"ssh://"}.size());
  }

  if (const auto at = host.rfind('@'); at != std::string_view::npos) {
    host.remove_prefix(at + 1);
  }

  while (host.starts_with('[')) {
    host.remove_prefix(1);
  }

  host = host.substr(0, host.find_first_of(":]/"));
  std::string label{host.substr(0, MachineLimits::label_bytes)};
  for (auto &byte : label) {
    if (!((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '.' || byte == '_' || byte == '-')) {
      byte = '-';
    }
  }

  if (options.new_label) {
    label = *options.new_label;
  }

  try {
    MachineFieldRules::label(label);
  } catch (const MachineFailure &) {
    if (!options.new_label) {
      throw CommandError{"MachineLabelNeeded"};
    }

    throw;
  }

  MachineOptions trial{.action = MachineOptions::Action::add, .label = label, .value = options.label};
  auto copy = profiles;
  change(copy, trial);
  return {.label = label, .destination = std::string{options.label}};
}

inline std::string fileDigest(const std::string &path) {
  FileDescriptor file{::open(path.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC)};
  struct stat state{};
  if (!file || ::fstat(file.get(), &state) != 0 || !S_ISREG(state.st_mode)) {
    throw CommandError{"SetupBinaryUnreadable"};
  }

  Sha256 digest;
  std::array<std::uint8_t, 64 * 1024> buffer;
  for (;;) {
    const auto count = ::read(file.get(), buffer.data(), buffer.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }

    if (count < 0) {
      throw CommandError{"SetupBinaryUnreadable"};
    }

    if (count == 0) {
      break;
    }

    digest.update({reinterpret_cast<const char *>(buffer.data()), static_cast<std::size_t>(count)});
  }

  const auto bytes = digest.finish();
  constexpr std::string_view hexadecimal = "0123456789abcdef";
  std::string text;
  for (const auto byte : bytes) {
    text += hexadecimal[byte >> 4];
    text += hexadecimal[byte & 15];
  }

  return text;
}

template <Allocator Memory>
std::optional<Platform> reach(Memory &memory, SetupReport &report, const Target &target, const std::string &directory) {
  launch::Output probe;
  bool confirmed = false;
  const auto run = [&] { return runScript(memory, target.destination, assign("dir", directory) + std::string{assets::probe}); };
  try {
    probe = run();
    const auto failure = sshFailure(probe);
    if (probe.status != 0 && !report.json && ::isatty(STDIN_FILENO) && (failure == MachineError::host_key_rejected || failure == MachineError::authentication_failed)) {
      std::printf("Batch-mode SSH to %s was refused. Connecting once with your terminal: OpenSSH asks, you answer; telar accepts nothing for you.\n", target.destination.c_str());
      std::fflush(stdout);
      confirmed = launch::inherit({"ssh", "-o", "ControlPath=none", "-o", "ForwardAgent=no", "--", target.destination, "true"}) == 0;
      if (confirmed) {
        probe = run();
      }
    }
  } catch (const std::exception &error) {
    report.end(Step::ssh, Status::failed, std::string{"ssh did not run to the end: "} + error.what());
    return std::nullopt;
  }

  if (probe.status != 0) {
    const auto failure = sshFailure(probe);
    if (probe.status != launch::ssh_failure && failure != MachineError::remote_runtime_incompatible) {
      report.end(Step::ssh, Status::ok, "batch-mode SSH to " + target.destination + " works");
      report.end(Step::platform, Status::failed, "the probe failed there: " + std::string{probe.errorLine()});
    } else if (failure == MachineError::authentication_failed) {
      report.end(Step::ssh, Status::failed, target.destination + (confirmed ? " accepts your login only interactively; windows need a key. Run `ssh-copy-id " + target.destination + "`, then setup again" : " refused the login in batch mode; add a key with `ssh-copy-id " + target.destination + "` or run setup from a terminal"));
    } else if (failure == MachineError::host_key_rejected) {
      report.end(Step::ssh, Status::failed, "the host key of " + target.destination + " is not confirmed: " + std::string{probe.errorLine()});
    } else {
      report.end(Step::ssh, Status::failed, std::string{probe.errorLine()});
    }

    return std::nullopt;
  }

  report.end(Step::ssh, confirmed ? Status::changed : Status::ok, "batch-mode SSH to " + target.destination + " works");
  try {
    const auto platform = Platform::parse(whole(probe));
    report.end(Step::platform, Status::ok, std::string{platform.os == "linux" ? "Linux " : "macOS "} + platform.arch + (platform.libc == "musl" ? " (musl)" : "") + ", " + platform.assetName());
    return platform;
  } catch (const std::exception &error) {
    report.end(Step::platform, Status::failed, std::string{error.what()} + ": " + probe.out.substr(0, probe.out.find('\n')));
    return std::nullopt;
  }
}

struct Install {
  std::optional<std::string> binary;
  std::optional<std::string> digest;
  std::string directory;
};

inline std::string releasesUrl() {
  const auto *configured = std::getenv("TELAR_RELEASES_URL");
  return configured && *configured ? configured : "https://github.com/adriangs1996/telar/releases";
}

inline std::string releaseDigest(const std::string &asset) {
  const auto url = releasesUrl() + "/download/v" + std::string{version} + "/SHA256SUMS";
  constexpr std::size_t max_url_bytes = 2048;
  if (url.size() >= max_url_bytes) {
    throw CommandError{"ReleaseUrlTooLong"};
  }

  launch::Output output;
  try {
    output = launch::capture({"curl", "--proto", "=https,file", "--tlsv1.2", "-fsSL", "--", url}, -1, probe_timeout);
  } catch (const std::exception &) {
    throw CommandError{"ReleaseUnavailable"};
  }

  constexpr std::size_t max_sums_bytes = 64 * 1024;
  if (output.status != 0 || output.dropped != 0 || output.out.size() > max_sums_bytes) {
    throw CommandError{"ReleaseUnavailable"};
  }

  std::istringstream lines{output.out};
  std::string line;
  while (std::getline(lines, line)) {
    std::istringstream words{line};
    std::string digest;
    std::string name;
    if (!(words >> digest >> name)) {
      continue;
    }

    if (name.starts_with('*')) {
      name.erase(0, 1);
    }

    if (name != asset) {
      continue;
    }

    constexpr std::size_t digest_hex_bytes = SHA256_DIGEST_LENGTH * 2;
    if (digest.size() != digest_hex_bytes || !std::ranges::all_of(digest, [](unsigned char byte) { return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F'); })) {
      throw CommandError{"ReleaseDigestUnreadable"};
    }

    return filter::lower(digest);
  }

  throw CommandError{"ReleaseAssetMissing"};
}

template <Allocator Memory>
std::optional<bool> installRuntime(Memory &memory, SetupReport &report, const Target &target, const Platform &platform, const Install &build) {
  if (!build.binary) {
    return false;
  }

  bool changed = false;
  for (const auto *tool : {"telar-runtime", "telar-config-check"}) {
    const auto sibling = std::filesystem::path{*build.binary}.parent_path() / tool;
    if (::access(sibling.c_str(), R_OK) != 0) {
      continue;
    }

    try {
      const auto digest = fileDigest(sibling.string());
      const auto remote = (std::filesystem::path{platform.target}.parent_path() / tool).string();
      static constexpr std::string_view hasher = R"Hash(hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}
)Hash";
      const auto inspect = runScript(memory, target.destination, assign("target", remote) + assign("expected", digest) + std::string{hasher} + "[ -f \"$target\" ] && [ \"$(hash \"$target\")\" = \"$expected\" ]\n");
      if (inspect.status == 0) {
        continue;
      }

      if (inspect.status == launch::ssh_failure) {
        throw CommandError{"SshFailed"};
      }

      FileDescriptor runtime{::open(sibling.c_str(), O_RDONLY | O_CLOEXEC)};
      if (!runtime) {
        throw fileError(errno);
      }

      const auto script = assign("target", remote) + assign("expected", digest) + std::string{hasher} + R"Upload(umask 077
temporary=$target.upload.$$
trap 'rm -f "$temporary"' EXIT
cat > "$temporary" && [ "$(hash "$temporary")" = "$expected" ] && chmod 755 "$temporary" && mv -f "$temporary" "$target"
)Upload";
      const auto command = "exec /bin/sh -c " + launch::quote(script);
      const auto uploaded = launch::capture(ssh(memory, target.destination, command), runtime.get(), install_timeout);
      if (uploaded.status != 0) {
        report.end(Step::telar, Status::failed, "the runtime upload failed: " + std::string{uploaded.errorLine()});
        return std::nullopt;
      }

      changed = true;
    } catch (const std::exception &error) {
      report.end(Step::telar, Status::failed, std::string{"the runtime upload did not run to the end: "} + error.what());
      return std::nullopt;
    }
  }

  return changed;
}

template <Allocator Memory>
bool install(Memory &memory, SetupReport &report, const Target &target, const Platform &platform, const Install &build) {
  try {
    MachineFieldRules::program(platform.target);
  } catch (const MachineFailure &) {
    report.end(Step::telar, Status::failed, platform.target + " holds a character a remote command cannot carry unquoted; telar needs a home of letters, digits and /._+-");
    return false;
  }

  if (platform.installed == "telar " + std::string{version}) {
    const auto runtime = installRuntime(memory, report, target, platform, build);
    if (!runtime) {
      return false;
    }

    report.end(Step::telar, *runtime ? Status::changed : Status::ok, (*runtime ? "installed telar " : "telar ") + std::string{version} + " at " + platform.target);
    return true;
  }

  std::string script;
  if (build.binary) {
    const auto upload_command = "exec /bin/sh -c 'umask 077 && mkdir -p \"$HOME/.local/share/telar/versions\" && exec cat > \"$HOME/.local/share/telar/versions/.upload-" + build.digest->substr(0, MachineId::hex_digits) + "\"'";
    FileDescriptor binary{::open(build.binary->c_str(), O_RDONLY | O_CLOEXEC)};
    if (!binary) {
      report.end(Step::telar, Status::failed, std::string{fileError(errno).what()} + ": cannot open --binary");
      return false;
    }

    try {
      const auto uploaded = launch::capture(ssh(memory, target.destination, upload_command), binary.get(), install_timeout);
      if (uploaded.status != 0) {
        report.end(Step::telar, Status::failed, "the upload failed: " + std::string{uploaded.errorLine()});
        return false;
      }
    } catch (const std::exception &error) {
      report.end(Step::telar, Status::failed, std::string{"the upload did not run to the end: "} + error.what());
      return false;
    }

    script = "upload=$HOME/.local/share/telar/versions/.upload-" + build.digest->substr(0, MachineId::hex_digits) + "\n";
    script += assign("digest", *build.digest) + assign("bin_dir", std::filesystem::path{platform.target}.parent_path().string());
    script += "(\nset -- --binary \"$upload\" --sha256 \"$digest\" --bin-dir \"$bin_dir\"\n";
  } else {
    if (version == "0.0.0") {
      report.end(Step::telar, Status::failed, "this is a development build (" + std::string{version} + ") with no release to download; pass --binary with a telar built for " + platform.os + " " + platform.arch);
      return false;
    }

    if (!platform.tools.contains("curl")) {
      report.end(Step::telar, Status::failed, target.label + " has no curl, which the installer needs to download the release; install curl there, or pass --binary");
      return false;
    }

    std::string digest;
    try {
      digest = releaseDigest(platform.assetName());
    } catch (const std::exception &error) {
      report.end(Step::telar, Status::failed, std::string{error.what()} + ": cannot read the hash of " + platform.assetName() + " from release " + std::string{version} + " at " + releasesUrl());
      return false;
    }

    script = assign("upload", "") + assign("digest", digest) + assign("version", version) + assign("bin_dir", std::filesystem::path{platform.target}.parent_path().string());
    if (const auto *url = std::getenv("TELAR_RELEASES_URL")) {
      script += assign("TELAR_RELEASES_URL", url) + "export TELAR_RELEASES_URL\n";
    }

    script += "(\nset -- --version \"$version\" --sha256 \"$digest\" --bin-dir \"$bin_dir\"";
    if (platform.os == "linux") {
      script += " --headless";
    }

    script += '\n';
  }

  script += assets::installer;
  script += "\n)\nstatus=$?\nif [ -n \"$upload\" ]; then rm -f \"$upload\"; fi\nexit $status\n";
  try {
    const auto output = runScript(memory, target.destination, script, install_timeout);
    if (output.status != 0) {
      report.end(Step::telar, Status::failed, "the installer refused: " + std::string{output.errorLine()});
      return false;
    }
  } catch (const std::exception &error) {
    report.end(Step::telar, Status::failed, std::string{"the installer did not run to the end: "} + error.what());
    return false;
  }

  if (!installRuntime(memory, report, target, platform, build)) {
    return false;
  }

  report.end(Step::telar, Status::changed, "installed telar " + std::string{version} + " at " + platform.target);
  return true;
}

template <Allocator Memory>
bool startRuntime(Memory &memory, SetupReport &report, const Target &target, const MachineProfile &remote, bool interactive) {
  const std::string program{*remote.program()};
  std::string detail;
  try {
    const auto found = discover(memory, remote, detail);
    if (!found.compatible()) {
      report.end(Step::runtime, Status::failed, "the telar at " + program + " speaks wire schema " + std::string{found.schema().begin(), found.schema().end()} + ", this one " + std::string{handshake::schema_id.begin(), handshake::schema_id.end()} + "; pass a --binary built from this tree");
      return false;
    }

    report.end(Step::runtime, Status::ok, "running at " + std::string{found.endpoint()});
    return true;
  } catch (const MachineFailure &error) {
    if (error.code() != MachineError::remote_runtime_incompatible) {
      report.end(Step::runtime, Status::failed, std::string{error.what()} + ": " + std::string{trimmed(detail)});
      return false;
    }
  }

  bool agreed = false;
  if (interactive) {
    std::printf("A telar runtime of another build runs on %s. Stopping it ends every pane and agent it runs. Stop it now? [y/N] ", target.label.c_str());
    std::fflush(stdout);
    agreed = answeredYes();
  }

  if (!agreed) {
    report.end(Step::runtime, Status::failed, "a runtime of another telar build runs there and keeps its panes; this build cannot attach until it stops. Run setup again from a terminal and agree to stop it");
    return false;
  }

  const auto script = assign("target", program) + assign("stopping", "is stopping") + R"Stop(for candidate in "$HOME/.local/bin/telar" "$HOME"/.local/share/telar/versions/*/telar $(command -v telar 2>/dev/null); do
    [ -x "$candidate" ] && [ "$candidate" != "$target" ] || continue
    if "$candidate" server stop 2>/dev/null | grep -q "$stopping"; then
        exit 0
    fi
done
echo 'no telar there could stop the running runtime' >&2
exit 1
)Stop";
  try {
    const auto stopped = runScript(memory, target.destination, script);
    if (stopped.status != 0) {
      report.end(Step::runtime, Status::failed, std::string{stopped.errorLine()});
      return false;
    }
  } catch (const std::exception &error) {
    report.end(Step::runtime, Status::failed, std::string{"stopping the old runtime did not run to the end: "} + error.what());
    return false;
  }

  constexpr unsigned restart_attempts = 20;
  constexpr auto restart_wait = std::chrono::milliseconds{250};
  for (unsigned attempt = 0; attempt < restart_attempts; ++attempt) {
    try {
      const auto found = discover(memory, remote, detail);
      if (found.compatible()) {
        report.end(Step::runtime, Status::changed, "stopped the runtime of another build; this one runs at " + std::string{found.endpoint()});
        return true;
      }
    } catch (const MachineFailure &) {
    }

    std::this_thread::sleep_for(restart_wait);
  }

  report.end(Step::runtime, Status::failed, "the old runtime stopped but this build's did not answer");
  return false;
}

template <Allocator Memory>
int setup(Memory &memory, const MachineOptions &options) {
  SetupReport report{.json = options.json};
  const auto path = profilesPath();
  const auto profiles = load(memory, path);
  Target target;
  Install build;
  try {
    target = resolve(profiles, options);
    build.directory = version;
    if (options.binary) {
      build.binary = *options.binary;
      build.digest = fileDigest(*build.binary);
      build.directory += "-" + build.digest->substr(0, MachineId::hex_digits);
      for (const auto *tool : {"telar-runtime", "telar-config-check"}) {
        const auto companion = std::filesystem::path{*build.binary}.parent_path() / tool;
        if (::access(companion.c_str(), R_OK) != 0) {
          throw CommandError{"SetupBinaryCompanionsMissing"};
        }

        build.directory += "-" + fileDigest(companion.string()).substr(0, MachineId::hex_digits);
      }
    }
  } catch (const std::exception &error) {
    if (std::string_view{error.what()} == "DuplicateMachineLabel") {
      std::fprintf(stderr, "telar machine setup: the label for %.*s is taken by another machine; name it with --label\n", static_cast<int>(options.label.size()), options.label.data());
    } else {
      const auto *detail = describe(error.what());
      std::fprintf(stderr, "telar machine setup: %s\n", detail ? detail : error.what());
    }

    return 1;
  }

  if (!options.json) {
    std::printf("Setting up %s (%s) with telar %.*s\n", target.label.c_str(), target.destination.c_str(), static_cast<int>(version.size()), version.data());
    std::fflush(stdout);
  }

  const bool interactive = !options.json && ::isatty(STDIN_FILENO);
  if (options.confirm) {
    if (!interactive) {
      return report.refuse(memory, target.label, target.destination, "--confirm needs a terminal to ask on; nothing was changed");
    }

    std::printf("This installs telar %.*s on %s (%s), and the agents you have here with their official installers; it copies their configuration, never a credential, and opens their logins there. Set it up? [y/N] ", static_cast<int>(version.size()), version.data(), target.label.c_str(), target.destination.c_str());
    std::fflush(stdout);
    if (!answeredYes()) {
      std::printf("Nothing was changed on %s.\n", target.label.c_str());
      return 0;
    }
  }

  const auto platform = reach(memory, report, target, build.directory);
  if (!platform || !install(memory, report, target, *platform, build)) {
    return report.finish(memory, target.label, target.destination);
  }

  Random random;
  auto remote = MachineProfile::create(MachineId::generate(random), {.label = target.label, .destination = target.destination, .program = platform->target});
  std::string detail;
  if (!startRuntime(memory, report, target, remote, interactive)) {
    return report.finish(memory, target.label, target.destination);
  }

  const auto link = runScript(memory, target.destination, assign("telar", platform->target) + R"Link(link=$HOME/.local/bin/telar
if [ -L "$link" ] && [ "$(readlink "$link")" = "$telar" ]; then exit 0; fi
if [ -e "$link" ] && [ ! -L "$link" ]; then echo 'it is a file telar did not link, so it stays; remove it to let setup link it' >&2; exit 1; fi
mkdir -p "$HOME/.local/bin" && "$telar" cli install --dir "$HOME/.local/bin" >/dev/null && echo linked
)Link");
  if (link.status != 0) {
    report.note(Step::runtime, "~/.local/bin/telar left as it was: " + std::string{link.errorLine()});
  } else if (link.out.contains("linked")) {
    report.note(Step::runtime, "~/.local/bin/telar now links to " + platform->target);
  }

  try {
    const auto previous = target.saved ? target.saved->program() : std::nullopt;
    const bool changed = !target.saved || previous != platform->target || (!target.saved->enabled() && !options.disabled);
    if (changed) {
      update(memory, path, [&](MachineProfiles &saved) {
        if (!target.saved) {
          MachineOptions add{.action = MachineOptions::Action::add, .label = target.label, .value = target.destination, .disabled = options.disabled};
          change(saved, add);
        }

        saved.placeProgram(target.label, platform->target);
        if (!options.disabled && target.saved) {
          saved.enable(target.label, true);
        }
      });
    }

    const bool enabled = (target.saved && target.saved->enabled()) || !options.disabled;
    const std::string state = enabled ? "enabled" : "disabled, as asked";
    report.end(Step::profile, changed ? Status::changed : Status::ok, changed ? target.label + (target.saved ? " updated, " : " saved, ") + state + ", telar at " + platform->target : target.label + " is saved, " + state + " and names " + platform->target);
  } catch (const std::exception &error) {
    const auto *description = describe(error.what());
    report.end(Step::profile, Status::failed, description ? description : error.what());
  }

  const auto wanted = localAgents();
  auto current = *platform;
  if (options.skip[0]) {
    report.end(Step::agents, Status::skipped, "--skip agents");
  } else if (installAgents(memory, report, target.destination, current, wanted)) {
    try {
      const auto probe = runScript(memory, target.destination, assign("dir", build.directory) + std::string{assets::probe});
      if (probe.status == 0) {
        current = Platform::parse(whole(probe));
      }
    } catch (const std::exception &) {
    }
  }

  integrateAgents(memory, report, target.destination, current);
  if (options.skip[1]) {
    report.end(Step::configuration, Status::skipped, "--skip config");
  } else {
    syncConfig(memory, report, target.destination, current, wanted);
  }

  if (options.skip[2]) {
    report.end(Step::logins, Status::skipped, "--skip login");
  } else {
    std::optional<MachineProfile> saved;
    try {
      const auto profiles_now = load(memory, path);
      if (const auto row = profiles_now.find(target.label); row && profiles_now.rows()[*row].destination() == target.destination) {
        saved = profiles_now.rows()[*row];
      }
    } catch (const std::exception &) {
    }

    if (saved) {
      Logins logins{memory, report, *saved, current, interactive};
      logins.run(wanted, path);
    } else {
      report.end(Step::logins, Status::skipped, target.label + " is not saved, so its logins cannot be recorded");
    }
  }

  try {
    const auto found = discover(memory, remote, detail);
    report.end(Step::check, found.compatible() ? Status::ok : Status::failed, found.compatible() ? "a window can attach: schema " + std::string{handshake::schema_id.begin(), handshake::schema_id.end()} + " on both sides" : "schema " + std::string{found.schema().begin(), found.schema().end()} + " there, " + std::string{handshake::schema_id.begin(), handshake::schema_id.end()} + " here");
  } catch (const MachineFailure &error) {
    report.end(Step::check, Status::failed, std::string{error.what()} + ": " + std::string{trimmed(detail)});
  }

  return report.finish(memory, target.label, target.destination);
}

}
}

// Interface: machine.cppm
export {
namespace telar::runtime::cli {

template <Allocator Memory>
int runMachine(Memory &memory, const MachineOptions &options) {
  if (options.action == MachineOptions::Action::receive_config) {
    return config_receive::run();
  }

  const auto path = machine::profilesPath();
  try {
    const auto profiles = machine::load(memory, path);
    switch (options.action) {
    case MachineOptions::Action::list:
      return machine::list(memory, profiles, options.json);
    case MachineOptions::Action::setup:
      return machine::setup(memory, options);
    case MachineOptions::Action::check: {
      const auto row = profiles.find(options.label);
      if (!row) {
        throw machines::MachineFailure{machines::MachineError::unknown_machine};
      }

      return machine::check(memory, profiles.rows()[*row], options.json);
    }

    case MachineOptions::Action::add: {
      const auto profile = machine::newProfile(profiles, options);
      if (options.check && !options.setup) {
        const auto status = machine::check(memory, profile, options.json);
        if (status != 0) {
          return status;
        }
      }

      break;
    }

    default:
      break;
    }

    machine::update(memory, path, [&](machines::MachineProfiles &saved) { machine::change(saved, options); });
    if (options.action == MachineOptions::Action::add && options.setup) {
      return machine::setup(memory, options);
    }

    return 0;
  } catch (const std::exception &error) {
    return machine::report(error);
  }
}

}
}
