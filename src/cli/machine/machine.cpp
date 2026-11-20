module telar.cli.machine;
import telar.platform.sha256;
import telar.sys.posix;

import telar.base.text;
import telar.base.text.utf8;
import telar.cli.base.command_error;
import telar.cli.control_session;
import telar.cli.server;
import telar.client;
import telar.tls;

import telar.tbc;
import telar.platform.fs;
import telar.cli.plugin;
import telar.base.text.json;
import telar.cli.command_limit;
import telar.cli.integration.settings;
import telar.cli.runtime_observer;
import telar.platform.paths;
import telar.platform.primitives;
import telar.platform.process;
import telar.wire.clients;
import telar.wire.vocabulary;
import telar.base.ds;
import telar.base.memory.containers;

namespace telar::runtime::cli::machine::assets {

#include "machine_assets.inc"

}

namespace telar::runtime::cli::machine {

  // Rewrites the profiles at `path` under an exclusive lock: `edit` changes what
  // was loaded, and the result replaces the file.
  // `path` from the working directory when it is relative.
  tbc::val_a<Text> absolutePath(tbc::mut_a<Memory> memory, std::string_view path) {
    if (path.starts_with('/')) {
      return Text{memory, path};
    }

    ds::Array<char, PATH_MAX> directory{};
    if (::getcwd(directory.dataMut(), directory.size()) == nullptr) {
      throw fileError(sys::lastError());
    }

    return ds::format(memory, "{}/{}", std::string_view{directory.data()}, path);
  }

  template <typename Edit>
  void update(Memory& memory, std::string_view path, Edit edit) {
    const auto absolute = absolutePath(memory, path);
    const auto slash = absolute.view().rfind('/');
    const auto name = absolute.view().substr(slash + 1);

    createPrivateDirectory(absolute.view().substr(0, slash == 0 ? 1 : slash));
    auto parent = openPrivateParent(absolute);
    const auto lock_name = ds::format(memory, "{}.lock", name);
    const auto lock = openLockFile(parent.get(), lock_name.data());
    struct stat state{};
    if (!lock || ::fstat(lock.get(), &state) != 0 || !S_ISREG(state.st_mode) || state.st_uid != ::geteuid() || (state.st_mode & 0077) != 0) {
      throw CommandError{"InsecureFile"};
    }

    while (::flock(lock.get(), LOCK_EX) != 0) {
      if (sys::lastError() != EINTR) {
        throw fileError(sys::lastError());
      }
    }

    auto profiles = load(memory, absolute);

    edit(profiles);
    const auto source = MachineProfileCodec::format(memory, profiles);
    const auto error = writePrivateFile(parent.get(), name, byteView(source), PrivateFileMode::replace);
    if (error != 0) {
      throw fileError(error);
    }
  }

  // What the probe found on the machine. The system, architecture and C library are one of the
  // names telar knows; the tools are a set over tool_names.
  struct Platform {
    static constexpr ds::Array<std::string_view, 5> tool_names{"curl", "tar", "bash", "node", "npm"};

    explicit Platform(Memory& memory)
        : home(memory),
          target(memory),
          agents(memory) {}

    std::string_view os;
    std::string_view arch;
    std::string_view libc;
    Text home;
    Text target;
    ds::Option<Text> installed;
    ds::Option<Text> node;
    std::uint8_t tools = 0;
    // Each agent's path there, by its name in machine_agent_names.
    ds::Map<std::string_view, Text, Memory> agents;

    bool has(std::string_view tool) const {
      const auto found = std::ranges::find(tool_names, tool);

      return found != tool_names.end() && ((tools >> (found - tool_names.begin())) & 1) != 0;
    }

    // The directory the telar binary sits in there.
    std::string_view binDirectory() const {
      const auto slash = target.view().rfind('/');

      return target.view().substr(0, slash == 0 ? 1 : slash);
    }

    static tbc::val_a<Platform> parse(tbc::mut_a<Memory> memory, std::string_view output) {
      constexpr std::size_t max_output = 8 * 1024;
      if (output.size() > max_output) {
        throw CommandError{"MachineProbeUnreadable"};
      }

      Platform result{memory};

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
        if (value.size() > MachineLimits::program_bytes || std::ranges::any_of(value, [](unsigned char byte) {
              return byte < 0x20 || byte == 0x7f;
            })) {
          throw CommandError{"MachineProbeUnreadable"};
        }

        const auto absolute = [&] {
          if (value.empty() || value.front() != '/') {
            throw CommandError{"MachineProbeUnreadable"};
          }

          return Text{memory, value};
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

          result.libc = value == "gnu" ? std::string_view{"gnu"} : std::string_view{"musl"};
        } else if (key == "home") {
          result.home = absolute();
        } else if (key == "target") {
          result.target = absolute();
        } else if (key == "installed") {
          result.installed = Text{memory, value};
        } else if (key == "node") {
          result.node = Text{memory, value};
        } else if (key == "tool") {
          const auto tool = std::ranges::find(tool_names, value);
          if (tool == tool_names.end()) {
            throw CommandError{"MachineProbeUnreadable"};
          }

          result.tools |= static_cast<std::uint8_t>(1u << (tool - tool_names.begin()));
        } else if (key == "agent") {
          const auto colon = value.find(':');
          const auto agent = std::ranges::find(machine_agent_names, value.substr(0, colon));
          if (colon == std::string_view::npos || agent == machine_agent_names.end() || colon + 1 == value.size() || value[colon + 1] != '/') {
            throw CommandError{"MachineProbeUnreadable"};
          }

          // The key is the static name, so it outlives the probe's output.
          const auto index = static_cast<std::size_t>(agent - machine_agent_names.begin());

          static_cast<void>(result.agents.assign(machine_agent_names[index], Text{memory, value.substr(colon + 1)}));
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

    tbc::val_a<Text> assetName(tbc::mut_a<Memory> memory) const {
      return ds::format(memory, "telar-{}-{}{}", os, arch, os == "linux" ? "-headless.tar.gz" : ".tar.gz");
    }
  };

  tbc::val_a<launch::Output> runScript(tbc::mut_a<Memory> memory, std::string_view destination, std::string_view script, std::chrono::seconds timeout = probe_timeout) {
    return launch::capture(memory, ssh(memory, destination, "exec /bin/sh -s").view(), script, timeout);
  }

  // Appends the shell assignment `name='value'` and a newline.
  void appendAssign(Text& script, std::string_view name, std::string_view value) {
    script.append(name);
    script.push('=');
    launch::appendQuoted(script, value);
    script.push('\n');
  }

  // The output, when nothing of it was dropped.
  std::string_view whole(const launch::Output& output) {
    if (output.dropped != 0) {
      throw CommandError{"RemoteOutputTooLong"};
    }

    return output.out.view();
  }

  bool answeredYes() {
    ds::Array<char, 18> answer{};
    if (!std::cin.getline(answer.dataMut(), answer.size())) {
      std::cin.clear();
      return false;
    }

    const auto text = trimText(std::string_view{answer.data()}, " \t\r\n");

    return asciiEqualIgnoreCase(text, "y") || asciiEqualIgnoreCase(text, "yes");
  }

  constexpr auto agent_names = ds::Array<std::string_view, 5>{"claude", "codex", "pi", "opencode", "cursor"};
  constexpr auto agent_commands = ds::Array<std::string_view, 5>{"claude", "codex", "pi", "opencode", "cursor-agent"};

  // A set of the agents agent_names lists, a bit for each.
  struct AgentSet {
    std::uint8_t bits = 0;

    static std::size_t index(std::string_view agent) {
      return static_cast<std::size_t>(std::ranges::find(agent_names, agent) - agent_names.begin());
    }

    bool contains(std::string_view agent) const {
      const auto at = index(agent);

      return at < agent_names.size() && ((bits >> at) & 1) != 0;
    }

    void insert(std::string_view agent) {
      if (const auto at = index(agent); at < agent_names.size()) {
        bits |= static_cast<std::uint8_t>(1u << at);
      }
    }

    bool empty() const {
      return bits == 0;
    }

    std::size_t size() const {
      return static_cast<std::size_t>(std::popcount(bits));
    }
  };

  AgentSet localAgents(Memory& memory) {
    AgentSet found;
    const auto* variable = std::getenv("PATH");
    if (!variable) {
      return found;
    }

    // Copied out of the environment, as std::env::var does: a call into the project may change it.
    const Text path{memory, variable};

    ds::Array<char, PATH_MAX> executable;

    for (std::size_t agent = 0; agent < agent_names.size(); ++agent) {
      if (findExecutable(path.view(), agent_commands[agent], executable.viewMut())) {
        found.insert(agent_names[agent]);
      }
    }

    return found;
  }

  // The agents' names, comma-separated; every name together fits.
  FixedText<64> names(AgentSet agents) {
    FixedText<64> text;
    ds::Array<char, 64> bytes;
    std::size_t size = 0;

    for (const auto agent : agent_names) {
      if (agents.contains(agent)) {
        size = static_cast<std::size_t>(std::format_to(bytes.dataMut() + size, "{}{}", size == 0 ? "" : ", ", agent) - bytes.dataMut());
      }
    }

    text.assign({bytes.data(), size});
    return text;
  }

  struct AgentInstaller {
    std::span<const std::string_view> tools;
    std::string_view script;
    bool musl = true;
  };

  AgentInstaller installerFor(std::string_view agent) {
    static constexpr ds::Array<std::string_view, 2> curl_bash{"curl", "bash"};
    static constexpr ds::Array<std::string_view, 2> curl_tar{"curl", "tar"};
    static constexpr ds::Array<std::string_view, 3> curl_node_npm{"curl", "node", "npm"};
    static constexpr ds::Array<std::string_view, 3> curl_bash_tar{"curl", "bash", "tar"};

    if (agent == "claude") {
      return {.tools = curl_bash.view(), .script = R"(if [ -f /etc/alpine-release ]; then
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
      return {.tools = curl_tar.view(), .script = "fetch https://chatgpt.com/codex/install.sh\nCODEX_NON_INTERACTIVE=1 sh \"$installer\" </dev/null\n"};
    }

    if (agent == "pi") {
      return {.tools = curl_node_npm.view(), .script = "fetch https://pi.dev/install.sh\nsh \"$installer\" </dev/null\n"};
    }

    if (agent == "opencode") {
      return {.tools = curl_bash_tar.view(), .script = "fetch https://opencode.ai/install\nbash \"$installer\" --no-modify-path </dev/null\n"};
    }

    return {.tools = curl_bash.view(), .script = "fetch https://cursor.com/install\nbash \"$installer\" </dev/null\n", .musl = false};
  }

  // One numeric part of a Node.js version, or nullopt when it is not a u32.
  ds::Option<std::uint32_t> maybeVersion(std::string_view part) noexcept {
    try {
      return parseInt<std::uint32_t>(part);
    } catch (const std::invalid_argument&) {
      return ds::none;
    }
  }

  using Reason = ErrorText<127>;

  ds::Option<Reason> missingPrerequisite(const Platform& platform, std::string_view agent, const AgentInstaller& installer) {
    if (platform.libc == "musl" && !installer.musl) {
      return Reason{"its binary needs glibc and this machine has musl"};
    }

    for (const auto tool : installer.tools) {
      if (!platform.has(tool)) {
        if (tool == "node" || tool == "npm") {
          return Reason{"Node.js 22.19 or newer with npm is missing there; its installer would need sudo or a terminal to add it"};
        }

        return Reason{tool, " is missing there"};
      }
    }

    if (agent == "pi") {
      auto text = platform.node ? platform.node->view() : std::string_view{};

      while (text.starts_with('v')) {
        text.remove_prefix(1);
      }

      const auto dot = text.find('.');
      const auto major = maybeVersion(text.substr(0, dot));
      const auto minor = dot == std::string_view::npos ? ds::none : maybeVersion(text.substr(dot + 1, text.find('.', dot + 1) - dot - 1));
      constexpr std::uint32_t required_major = 22;
      constexpr std::uint32_t required_minor = 19;
      if (!major || !minor || *major < required_major || (*major == required_major && *minor < required_minor)) {
        return Reason{"Node.js there is older than 22.19"};
      }
    }

    return ds::none;
  }

  bool installAgents(Memory& memory, SetupReport& report, std::string_view destination, const Platform& platform, AgentSet wanted) {
    if (wanted.empty()) {
      report.end(Step::agents, Status::skipped, "no agent on this machine's PATH to install there");
      return false;
    }

    bool ran = false;
    bool failed = false;

    for (const auto agent : agent_names) {
      if (!wanted.contains(agent)) {
        continue;
      }

      if (const auto* existing = platform.agents.find(agent)) {
        report.note(Step::agents, "{}: already at {}", agent, *existing);
        continue;
      }

      const auto installer = installerFor(agent);
      if (const auto missing = missingPrerequisite(platform, agent, installer)) {
        report.note(Step::agents, "{}: not installed: {}", agent, missing->view());
        continue;
      }

      ran = true;
      report.progress("installing {} there with its official installer", agent);
      static constexpr std::string_view prelude = R"Agent(set -eu
installer=$(mktemp "${TMPDIR:-/tmp}/telar-agent-installer.XXXXXX")
trap 'rm -f "$installer"' EXIT
fetch() {
    curl --proto '=https' --tlsv1.2 -fsSL "$1" -o "$installer"
}
)Agent";

      try {
        const auto output = runScript(memory, destination, ds::format(memory, "{}{}", prelude, installer.script), install_timeout);
        if (output.status == 0) {
          report.note(Step::agents, "{}: installed with its official installer", agent);
        } else {
          report.note(Step::agents, "{}: its installer failed: {}", agent, output.errorLine());
          failed = true;
        }
      } catch (const std::exception& error) {
        report.note(Step::agents, "{}: its installer did not run to the end: {}", agent, error.what());
        failed = true;
      }
    }

    report.end(Step::agents, failed ? Status::failed : ran ? Status::changed
                                                           : Status::ok,
        "{} wanted: {}",
        wanted.size(),
        names(wanted).view());
    return ran;
  }

  void integrateAgents(Memory& memory, SetupReport& report, std::string_view destination, const Platform& platform) {
    if (platform.agents.empty()) {
      report.end(Step::integrations, Status::skipped, "no agent there");
      return;
    }

    bool changed = false;
    bool failed = false;
    AgentSet present;

    for (const auto agent : agent_names) {
      if (!platform.agents.contains(agent)) {
        continue;
      }

      present.insert(agent);
      try {
        Text script{memory};

        appendAssign(script, "telar", platform.target);
        appendAssign(script, "agent", agent);
        script.append("exec \"$telar\" integration install \"$agent\"\n");
        const auto output = runScript(memory, destination, script);
        if (output.status != 0) {
          report.note(Step::integrations, "{}: {}", agent, output.errorLine());
          failed = true;
          continue;
        }

        const bool unchanged = whole(output).contains("already present");

        changed = changed || !unchanged;
        report.note(Step::integrations, "{}: {}", agent, unchanged ? "already integrated" : "integrated");
      } catch (const std::exception& error) {
        report.note(Step::integrations, "{}: {}", agent, error.what());
        failed = true;
      }
    }

    report.end(Step::integrations, failed ? Status::failed : changed ? Status::changed
                                                                     : Status::ok,
        "{}",
        names(present).view());
  }

  constexpr unsigned config_json_depth = 256;

  struct SyncEntry {
    tbc::val_static<std::string_view> name;
    enum class Format {
      text,
      json,
      toml,
      tree,
    } format = Format::text;
    bool hooks = false;
  };

  std::span<const SyncEntry> entriesFor(std::string_view agent) {
    using enum SyncEntry::Format;
    static constexpr ds::Array<SyncEntry, 9> claude{{{"settings.json", json, true}, {"CLAUDE.md"}, {"keybindings.json", json}, {"rules", tree}, {"skills", tree}, {"commands", tree}, {"agents", tree}, {"output-styles", tree}, {"themes", tree}}};
    static constexpr ds::Array<SyncEntry, 6> codex{{{"config.toml", toml}, {"hooks.json", json, true}, {"AGENTS.md"}, {"AGENTS.override.md"}, {"rules", tree}, {"prompts", tree}}};
    static constexpr ds::Array<SyncEntry, 9> pi{{{"settings.json", json}, {"keybindings.json", json}, {"AGENTS.md"}, {"SYSTEM.md"}, {"APPEND_SYSTEM.md"}, {"skills", tree}, {"prompts", tree}, {"themes", tree}, {"extensions", tree}}};
    static constexpr ds::Array<SyncEntry, 10> opencode{{{"opencode.json", json}, {"opencode.jsonc", json}, {"tui.json", json}, {"AGENTS.md"}, {"agents", tree}, {"commands", tree}, {"modes", tree}, {"skills", tree}, {"themes", tree}, {"plugins", tree}}};
    static constexpr ds::Array<SyncEntry, 4> cursor{{{"cli-config.json", json}, {"hooks.json", json, true}, {"skills", tree}, {"agents", tree}}};

    if (agent == "claude") {
      return claude.view();
    }

    if (agent == "codex") {
      return codex.view();
    }

    if (agent == "pi") {
      return pi.view();
    }

    if (agent == "opencode") {
      return opencode.view();
    }

    return cursor.view();
  }

  std::string_view remoteRoot(std::string_view agent) {
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

  tbc::val_a<Text> localRoot(tbc::mut_a<Memory> memory, std::string_view agent, std::string_view home) {
    const auto* variable = agent == "claude" ? "CLAUDE_CONFIG_DIR" : agent == "codex"  ? "CODEX_HOME"
                                                                 : agent == "pi"       ? "PI_CODING_AGENT_DIR"
                                                                 : agent == "opencode" ? "XDG_CONFIG_HOME"
                                                                                       : "CURSOR_CONFIG_DIR";
    const auto* set = std::getenv(variable);
    const Text override{memory, set == nullptr ? std::string_view{} : std::string_view{set}};

    return !override.empty() ? ds::format(memory, "{}{}", override.view(), agent == "opencode" ? "/opencode" : "") : ds::format(memory, "{}/{}", home, remoteRoot(agent));
  }

  // Calls `visit` with each word of a shell command, split at its separators.
  template <typename Visit>
  void commandTokens(std::string_view command, Visit&& visit) {
    constexpr std::string_view separators = " \t\n;&|()'\"=";

    while (!command.empty()) {
      const auto start = command.find_first_not_of(separators);
      if (start == std::string_view::npos) {
        break;
      }

      command.remove_prefix(start);
      const auto end = command.find_first_of(separators);

      visit(command.substr(0, end));
      if (end == std::string_view::npos) {
        break;
      }

      command.remove_prefix(end + 1);
    }
  }

  tbc::val_a<ds::Option<Text>> homePath(tbc::mut_a<Memory> memory, std::string_view token, std::string_view home) {
    for (const auto prefix : {"~/", "$HOME/", "${HOME}/"}) {
      if (token.starts_with(prefix)) {
        return ds::format(memory, "{}/{}", home, token.substr(std::string_view{prefix}.size()));
      }
    }

    if (token.starts_with(home) && token.substr(home.size()).starts_with('/')) {
      return Text{memory, token};
    }

    return ds::none;
  }

  void commands(Memory& memory, JsonValue value, ds::Vec<Text, Memory>& output, bool inside = false) {
    if (value.encoded().starts_with('{')) {
      value.eachMember([&](JsonValue key, JsonValue child) {
        Text name{memory};

        key.string(name);
        if (inside && name == "command" && child.encoded().starts_with('"')) {
          Text text{memory};

          child.string(text);
          output.push(std::move(text));
        }

        commands(memory, child, output, inside || name == "hooks" || name == "statusLine");
      });
    } else if (value.encoded().starts_with('[')) {
      value.eachElement([&](JsonValue child) {
        commands(memory, child, output, inside);
      });
    }
  }

  // Texts kept sorted, without repeats, for lookups by binary search.
  class SortedTexts {
  public:
    // Copies what it keeps into `memory`.
    explicit SortedTexts(tbc::mut_a<Memory> memory)
        : texts_(memory) {}

    void insert(std::string_view text) {
      const auto at = std::ranges::lower_bound(texts_, text, {}, &Text::view);
      if (at != texts_.end() && *at == text) {
        return;
      }

      static_cast<void>(texts_.insert(static_cast<std::size_t>(at - texts_.begin()), Text{texts_.memory(), text}));
    }

    bool contains(std::string_view text) const {
      return std::ranges::binary_search(texts_, text, {}, &Text::view);
    }

  private:
    tbc::val_a<ds::Vec<Text, Memory>> texts_;
  };

  class ConfigSync {
    struct File {
      Text remote;
      Text bytes;
      SyncEntry::Format format;
      // The agent whose hooks the file holds, by its static name.
      ds::Option<std::string_view> hooks;
      mode_t mode;
      ds::Option<JsonNode<Memory>> json;
    };

    struct Root {
      Text remote;
      Text real;
    };

    // Everything below lives in memory_'s region.
    tbc::mut_a<Memory> memory_;
    tbc::val_a<Text> home_;
    tbc::val_a<Text> remote_home_;
    tbc::val_a<ds::Vec<Root, Memory>> roots_;
    // Each wanted agent's local root, in the agents' alphabetical order.
    tbc::val_a<ds::Vec<std::pair<std::string_view, Text>, Memory>> local_roots_;
    tbc::val_a<ds::Vec<File, Memory>> files_;
    tbc::val_a<ds::Vec<Text, Memory>> left_;
    std::size_t total_ = 0;

    template <typename... Arguments>
    void leave(std::format_string<Arguments...> format, Arguments&&... arguments) {
      left_.push(ds::format(memory_, format, std::forward<Arguments>(arguments)...));
    }

    static bool below(std::string_view path, std::string_view root) {
      return path.starts_with(root) && path.size() > root.size() && path[root.size()] == '/';
    }

    // The canonical path of `path`, when it resolves.
    tbc::val_a<ds::Option<Text>> canonical(std::string_view path) const {
      const Text given{memory_, path};
      ds::Array<char, PATH_MAX> resolved{};
      if (::realpath(given.data(), resolved.dataMut()) == nullptr) {
        return ds::none;
      }

      return Text{memory_, std::string_view{resolved.data()}};
    }

    bool inside(std::string_view remote, std::string_view real) const {
      for (const auto& root : roots_) {
        if (below(remote, root.remote)) {
          return real == root.real.view() || below(real, root.real);
        }
      }

      return false;
    }

    bool staged(std::string_view path) const {
      return std::ranges::any_of(files_, [&](const File& file) {
        return file.remote == path;
      });
    }

    bool addRoot(std::string_view remote, std::string_view local) {
      auto real = canonical(local);
      if (!real) {
        return false;
      }

      roots_.push(Root{.remote = Text{memory_, remote}, .real = std::move(real.getMut())});
      return true;
    }

    // What telar installs in an agent's directory itself, which setup leaves to the other
    // machine's telar. `remote` names a file from the home; each path is from an agent's root,
    // or from the parent of a shared root such as .agents/skills.
    bool owned(std::string_view remote) const {
      static constexpr auto paths = ds::Array<std::string_view, 4>{"skills/telar", "skills/telar-coordinator", "extensions/telar.ts", "plugins/telar.ts"};
      const auto matches = [](std::string_view relative) {
        return std::ranges::any_of(paths, [&](auto path) {
          return relative == path || below(relative, path);
        });
      };

      return std::ranges::any_of(roots_, [&](const Root& root) {
        if (!below(remote, root.remote)) {
          return false;
        }

        const auto relative = remote.substr(root.remote.size() + 1);
        const auto base = root.remote.view();
        const auto parent = base.substr(base.rfind('/') + 1);

        return matches(relative) || matches(ds::format(memory_, "{}/{}", parent, relative));
      });
    }

    void addFile(std::string_view local, std::string_view remote, SyncEntry entry) {
      if (staged(remote)) {
        return;
      }

      const auto real = canonical(local);
      if (!real) {
        return;
      }

      // Apply the same denylist to the original and canonical file names.
      if (!config_receive::acceptable(remote) || !safeLocal(local) || !safeLocal(*real)) {
        leave("{}: never sent", remote);
        return;
      }

      if (!inside(remote, *real)) {
        leave("{}: leads outside its agent's directory, not sent", remote);
        return;
      }

      FileDescriptor file{::open(real->data(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)};
      struct stat state{};
      if (!file || ::fstat(file.get(), &state) != 0 || !S_ISREG(state.st_mode)) {
        return;
      }

      if (state.st_nlink > 1) {
        leave("{}: has another hard link, which could be any file; not sent", remote);
        return;
      }

      if (state.st_size < 0 || static_cast<std::uint64_t>(state.st_size) > config_receive::max_file_bytes) {
        leave("{}: larger than 1024 KiB, not sent", remote);
        return;
      }

      if (files_.size() == config_receive::max_files || total_ + static_cast<std::uint64_t>(state.st_size) > config_receive::max_total_bytes) {
        leave("{}: the sync is full, not sent", remote);
        return;
      }

      Text bytes{memory_};
      ds::Array<char, 16 * 1024> buffer;

      for (;;) {
        const auto count = ::read(file.get(), buffer.dataMut(), buffer.size());
        if (count < 0 && sys::lastError() == EINTR) {
          continue;
        }

        if (count < 0) {
          return;
        }

        if (count == 0) {
          break;
        }

        if (bytes.size() + static_cast<std::size_t>(count) > config_receive::max_file_bytes) {
          leave("{}: larger than 1024 KiB, not sent", remote);
          return;
        }

        bytes.append({buffer.data(), static_cast<std::size_t>(count)});
      }

      total_ += bytes.size();
      files_.push(File{.remote = Text{memory_, remote}, .bytes = std::move(bytes), .format = entry.format, .hooks = entry.hooks ? ds::Option{entry.name} : ds::none, .mode = static_cast<mode_t>((state.st_mode & 0111) != 0 ? 0755 : 0644), .json = ds::none});
    }

    static bool safeLocal(std::string_view path) {
      // The canonical path can have arbitrary non-agent ancestors; keep only
      // their names for the denylist, then reuse acceptable's leaf checks.
      auto tail = path;
      const auto& directories = config_receive::credential_directories;

      for (;;) {
        const auto slash = tail.find('/');
        const auto component = tail.substr(0, slash);
        if (std::ranges::any_of(directories, [&](auto directory) {
              return asciiEqualIgnoreCase(component, directory);
            })) {
          return false;
        }

        if (slash == std::string_view::npos) {
          break;
        }

        tail.remove_prefix(slash + 1);
      }

      ds::Array<char, NAME_MAX + 16> leaf;
      const auto written = std::format_to_n(leaf.dataMut(), leaf.size(), ".claude/{}", path.substr(path.rfind('/') + 1));

      return static_cast<std::size_t>(written.size) <= leaf.size() && config_receive::acceptable({leaf.data(), static_cast<std::size_t>(written.size)});
    }

    void addTree(std::string_view local, std::string_view remote, unsigned depth) {
      constexpr unsigned max_depth = 16;

      if (owned(remote)) {
        return;
      }

      if (depth > max_depth) {
        leave("{}/: deeper than 16 directories, not sent", remote);
        return;
      }

      const auto real = canonical(local);
      if (!real) {
        return;
      }

      if (!inside(remote, *real)) {
        leave("{}/: leads outside its agent's directory, not sent", remote);
        return;
      }

      const Text local_text{memory_, local};
      FileDescriptor directory{::open(local_text.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
      if (!directory) {
        return;
      }

      DirectoryStream entries{directory.get()};

      while (const auto* entry = entries.next()) {
        const std::string_view name{entry->d_name};
        if (name.empty() || name.front() == '.') {
          continue;
        }

        const auto target = ds::format(memory_, "{}/{}", remote, name);
        if (owned(target)) {
          continue;
        }

        // As the directory listing's types do, through symlinks.
        struct stat state{};
        if (::fstatat(directory.get(), entry->d_name, &state, 0) != 0) {
          continue;
        }

        const auto child = ds::format(memory_, "{}/{}", local, name);

        if (S_ISDIR(state.st_mode)) {
          addTree(child, target, depth + 1);
        } else if (S_ISREG(state.st_mode)) {
          addFile(child, target, {});
        }
      }
    }

    bool keep(std::size_t index, Text bytes) {
      if (const auto found = filter::findSecret(bytes)) {
        // Formatted before it is kept: leaving mutates the sync, files included.
        auto message = ds::format(memory_, "{}: held back, line {} holds what looks like {}; review it and sync again", files_[index].remote, found->first, found->second);

        left_.push(std::move(message));
        return false;
      }

      files_.atMut(index).bytes = std::move(bytes);
      return true;
    }

    void bringCommands(const JsonValue& value) {
      ds::Vec<Text, Memory> found{memory_};

      commands(memory_, value, found);
      for (const auto& command : found) {
        commandTokens(command, [&](std::string_view token) {
          const auto local = homePath(memory_, token, home_);
          if (!local) {
            return;
          }

          // The roots are read before files are added, as adding one changes the plan.
          ds::Vec<Text, Memory> remotes{memory_};

          for (const auto& [agent, root] : local_roots_) {
            if (below(*local, root)) {
              remotes.push(ds::format(memory_, "{}{}", remoteRoot(agent), local->view().substr(root.size())));
            }
          }

          for (const auto& remote : remotes) {
            addFile(*local, remote, {});
          }
        });
      }
    }

    void transform(std::string_view program) {
      for (std::size_t index = 0; index < files_.size();) {
        // Copied: bringing commands adds files, which can move these.
        const auto original = files_[index].bytes.clone();
        const auto path = files_[index].remote.clone();
        const auto hooks = files_[index].hooks;
        filter::Notes dropped{memory_};
        bool retain = true;

        if (files_[index].format == SyncEntry::Format::json) {
          try {
            const auto plain = filter::stripJsonc(memory_, original);

            // Validate duplicates and UTF-8 before traversing JsonValue.
            static_cast<void>(JsonNode<Memory>::parse(memory_, plain));
            Text filtered{memory_};

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

            files_.atMut(index).json = std::move(node);
          } catch (const CommandError& error) {
            if (std::string_view{error.what()} != "UnterminatedComment") {
              throw;
            }

            leave("{}: not valid JSON here, not sent", path);
            retain = false;
          } catch (const std::bad_alloc&) {
            throw;
          } catch (const std::exception&) {
            leave("{}: not valid JSON here, not sent", path);
            retain = false;
          }
        } else {
          const auto filtered = files_[index].format == SyncEntry::Format::toml ? filter::toml(memory_, original, dropped) : original.clone();

          retain = keep(index, filter::rewriteHome(memory_, filtered, home_, remote_home_));
        }

        if (!dropped.empty()) {
          auto note = ds::format(memory_, "{}: left out ", path);

          for (const auto& name : dropped) {
            ds::formatTo(note, "{}{}", &name == dropped.data() ? "" : ", ", name);
          }

          left_.push(std::move(note));
        }

        if (retain) {
          ++index;
        } else {
          static_cast<void>(files_.remove(index));
        }
      }
    }

    Text rewriteJson(JsonValue value) {
      Text output{memory_};
      const auto encoded = value.encoded();
      if (encoded.starts_with('"')) {
        Text text{memory_};

        value.string(text);
        appendJsonText(output, filter::rewriteHome(memory_, text, home_, remote_home_).view(), JsonEscapes::standard);
      } else if (encoded.starts_with('{')) {
        output.push('{');
        bool first = true;

        value.eachMember([&](JsonValue key, JsonValue child) {
          if (!first) {
            output.push(',');
          }

          first = false;
          output.append(key.encoded());
          output.push(':');
          output.append(rewriteJson(child));
        });

        output.push('}');
      } else if (encoded.starts_with('[')) {
        output.push('[');
        bool first = true;

        value.eachElement([&](JsonValue child) {
          if (!first) {
            output.push(',');
          }

          first = false;
          output.append(rewriteJson(child));
        });

        output.push(']');
      } else {
        output.append(encoded);
      }

      return output;
    }

    // The absolute paths a command names there: its absolute words and its words under the home.
    template <typename Visit>
    static void paths(Memory& memory, std::string_view remote_home, std::string_view command, Visit&& visit) {
      commandTokens(command, [&](std::string_view token) {
        if (token.starts_with('/')) {
          visit(token);
        } else if (const auto expanded = homePath(memory, token, remote_home)) {
          visit(expanded->view());
        }
      });
    }

    SortedTexts queryPaths(std::string_view destination) {
      ds::Vec<Text, Memory> asked{memory_};

      for (const auto& file : files_) {
        if (!file.json) {
          continue;
        }

        ds::Vec<Text, Memory> found{memory_};
        const auto formatted = file.json->format();

        commands(memory_, JsonValue::parse(formatted, config_json_depth), found);
        for (const auto& command : found) {
          paths(memory_, remote_home_, command, [&](std::string_view path) {
            if (!path.contains('\n') && path != "TELAR_PATHS") {
              asked.emplace(memory_, path);
            }
          });
        }
      }

      SortedTexts result{memory_};

      if (asked.empty()) {
        return result;
      }

      Text script{memory_, "while IFS= read -r path; do if [ -e \"$path\" ]; then printf '%s\\n' \"$path\"; fi; done <<'TELAR_PATHS'\n"};

      for (const auto& path : asked) {
        ds::formatTo(script, "{}\n", path);
      }

      script.append("TELAR_PATHS\n");
      const auto output = runScript(memory_, destination, script);
      if (output.status != 0) {
        throw CommandError{"MachinePathsUnreadable"};
      }

      auto lines = output.out.view();

      if (output.dropped != 0) {
        throw CommandError{"RemoteOutputTooLong"};
      }

      while (!lines.empty()) {
        const auto end = lines.find('\n');
        if (const auto line = lines.substr(0, end); !line.empty()) {
          result.insert(line);
        }

        if (end == std::string_view::npos) {
          break;
        }

        lines.remove_prefix(end + 1);
      }

      return result;
    }

    static bool commandRuns(Memory& memory, std::string_view remote_home, const SortedTexts& staged, std::string_view command, const SortedTexts& existing) {
      if (command.ends_with(" hook claude") || command.ends_with(" hook codex") || command.ends_with(" hook cursor")) {
        return true;
      }

      bool runs = true;

      paths(memory, remote_home, command, [&](std::string_view path) {
        if (existing.contains(path) || (below(path, remote_home) && staged.contains(path.substr(remote_home.size() + 1)))) {
          return;
        }

        runs = false;
      });

      return runs;
    }

    // Leaves out the commands whose programs the machine lacks, noting each in `left`. Static, so a call
    // takes the sync's fields apart from the file whose commands it prunes.
    static bool keepCommands(std::string_view remote_home, ds::Vec<Text, Memory>& left, const SortedTexts& staged, JsonNode<Memory>& node, const SortedTexts& existing, std::string_view path) {
      auto& memory = left.memory();

      if (node.kind() == JsonKind::object) {
        if (const auto* command = node.find("command"); command && command->kind() == JsonKind::string && !commandRuns(memory, remote_home, staged, command->text(), existing)) {
          left.push(ds::format(memory, "{}: left out `{}`, whose program is not there", path, command->text()));
          return false;
        }
      }

      if (node.kind() == JsonKind::array || node.kind() == JsonKind::object) {
        const bool had_items = !node.children().empty();

        for (std::size_t index = 0; index < node.children().size();) {
          auto& child = node.childrenMut()[index];
          const bool container = child.kind() == JsonKind::object || child.kind() == JsonKind::array;
          const bool recurse = container && (node.kind() == JsonKind::array || !child.children().empty());
          if (recurse && !keepCommands(remote_home, left, staged, child, existing, path)) {
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
    ConfigSync(tbc::mut_a<Memory> memory, std::string_view home, std::string_view remote_home)
        : memory_(memory),
          home_(memory, home),
          remote_home_(memory, remote_home),
          roots_(memory),
          local_roots_(memory),
          files_(memory),
          left_(memory) {}

    void run(SetupReport& report, std::string_view destination, const Platform& platform, AgentSet wanted) {
      for (const auto agent : agent_names) {
        if (!wanted.contains(agent)) {
          continue;
        }

        auto root = localRoot(memory_, agent, home_);
        const auto remote = remoteRoot(agent);
        if (!addRoot(remote, root)) {
          local_roots_.push({agent, std::move(root)});
          continue;
        }

        for (const auto& entry : entriesFor(agent)) {
          const auto local_path = ds::format(memory_, "{}/{}", root, entry.name);
          const auto remote_path = ds::format(memory_, "{}/{}", remote, entry.name);

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

        local_roots_.push({agent, std::move(root)});
      }

      std::ranges::sort(local_roots_.viewMut(), {}, &std::pair<std::string_view, Text>::first);
      if (wanted.contains("codex") || wanted.contains("opencode") || wanted.contains("cursor")) {
        constexpr std::string_view shared = ".agents/skills";
        const auto local = ds::format(memory_, "{}/{}", home_, shared);
        if (addRoot(shared, local)) {
          addTree(local, shared, 0);
        }
      }

      transform(platform.target);
      const auto existing = queryPaths(destination);
      // The files already staged, named apart from the files the commands are pruned in.
      SortedTexts staged{memory_};

      for (const auto& file : files_) {
        staged.insert(file.remote);
      }

      for (auto& file : files_.viewMut()) {
        if (!file.json || file.json->kind() != JsonKind::object) {
          continue;
        }

        if (auto* status = file.json.getMut().findMut("statusLine"); status && !keepCommands(remote_home_, left_, staged, *status, existing, file.remote)) {
          file.json.getMut().remove("statusLine");
        }

        if (auto* hooks = file.json.getMut().findMut("hooks")) {
          keepCommands(remote_home_, left_, staged, *hooks, existing, file.remote);
        }
      }

      Text stream{memory_, "telar-config 1\n"};

      for (std::size_t index = 0; index < files_.size();) {
        if (files_[index].json) {
          if (!keep(index, Text{memory_, files_[index].json->format()})) {
            static_cast<void>(files_.remove(index));
            continue;
          }
        }

        const auto& file = files_[index];

        ds::formatTo(stream, "file {} {} {}\n{}\n", file.mode == 0755 ? "755" : "644", file.bytes.size(), file.remote, file.bytes);
        ++index;
      }

      stream.append("end\n");
      constexpr auto send_timeout = std::chrono::seconds{600};
      const auto output = launch::capture(memory_, ssh(memory_, destination, ds::format(memory_, "{} machine receive-config", platform.target)).view(), stream, send_timeout);
      if (output.status != 0) {
        report.end(Step::configuration, Status::failed, "the machine refused the sync: {}", output.errorLine());
        return;
      }

      auto lines = whole(output);
      std::size_t written = 0;

      while (!lines.empty()) {
        const auto end = lines.find('\n');
        const auto line = lines.substr(0, end);
        if (line.starts_with("written ")) {
          ++written;
          report.note(Step::configuration, "{}", line);
        } else if (line.starts_with("refused ")) {
          report.note(Step::configuration, "left alone there: {}", line.substr(8));
        }

        if (end == std::string_view::npos) {
          break;
        }

        lines.remove_prefix(end + 1);
      }

      for (const auto& line : left_) {
        report.note(Step::configuration, "{}", line);
      }

      report.end(Step::configuration, written != 0 ? Status::changed : Status::ok, "{} of {} files written; credentials, sessions and history stay here", written, files_.size());
    }
  };

  void syncConfig(Memory& memory, SetupReport& report, std::string_view destination, const Platform& platform, AgentSet wanted) {
    if (wanted.empty()) {
      report.end(Step::configuration, Status::skipped, "no agent here to take configuration from");
      return;
    }

    try {
      const auto* variable = std::getenv("HOME");
      if (!variable) {
        throw CommandError{"HomeUnavailable"};
      }

      const Text home{memory, variable};
      ConfigSync sync{memory, home.view(), platform.home};

      sync.run(report, destination, platform, wanted);
    } catch (const std::exception& error) {
      report.end(Step::configuration, Status::failed, "{}; nothing more was written there", error.what());
    }
  }

  // The decimal digits of a number, as a command argument.
  FixedText<24> decimal(std::uint64_t value) {
    ds::Array<char, 24> digits;
    FixedText<24> text;

    text.assign({digits.data(), std::to_chars(digits.dataMut(), digits.dataMut() + digits.size(), value).ptr});
    return text;
  }

  // How setup logs an agent in on the machine. Every text is the plan's own, static.
  struct LoginPlan {
    std::string_view title;
    std::span<const std::string_view> arguments;
    ds::Option<std::string_view> environment;
    ds::Option<std::string_view> keys;
    bool link = true;
    std::span<const std::string_view> hosts;
    ds::Option<std::string_view> code_marker;
    ds::Option<std::string_view> paste;
    std::string_view instructions;
  };

  tbc::val_static<ds::Option<LoginPlan>> planFor(std::string_view agent, ds::Option<std::string_view> provider) {
    static constexpr ds::Array<std::string_view, 2> auth_login{"auth", "login"};
    static constexpr ds::Array<std::string_view, 2> device_login{"login", "--device-auth"};
    static constexpr ds::Array<std::string_view, 1> login{"login"};
    static constexpr ds::Array<std::string_view, 6> openai_login{"auth", "login", "-p", "openai", "-m", "ChatGPT Pro/Plus (headless)"};
    static constexpr ds::Array<std::string_view, 3> claude_hosts{"claude.com", "claude.ai", "platform.claude.com"};
    static constexpr ds::Array<std::string_view, 1> openai_hosts{"auth.openai.com"};
    static constexpr ds::Array<std::string_view, 1> cursor_hosts{"cursor.com"};

    if (agent == "claude") {
      return LoginPlan{.title = "Log in to Claude Code", .arguments = auth_login.view(), .hosts = claude_hosts.view(), .paste = "the code the browser shows", .instructions = "open the page, sign in, and paste the code it shows into this terminal"};
    }

    if (agent == "codex") {
      return LoginPlan{.title = "Log in to Codex", .arguments = device_login.view(), .hosts = openai_hosts.view(), .code_marker = "one-time code", .instructions = "open the page, sign in and enter the code"};
    }

    if (agent == "cursor") {
      return LoginPlan{.title = "Log in to Cursor Agent", .arguments = login.view(), .environment = "NO_OPEN_BROWSER=1", .hosts = cursor_hosts.view(), .instructions = "open the page and sign in"};
    }

    if (agent == "pi" && provider) {
      return LoginPlan{.title = "Log in to Pi", .keys = "/login", .link = false, .instructions = "choose the provider in the Pi pane there"};
    }

    if (agent == "opencode" && provider == ds::Option<std::string_view>{"openai"}) {
      return LoginPlan{.title = "Log in to OpenCode", .arguments = openai_login.view(), .hosts = openai_hosts.view(), .code_marker = "Enter code:", .instructions = "open the page, sign in and enter the code"};
    }

    return ds::none;
  }

  struct LoginPane {
    std::uint64_t workspace = 0;
    std::uint64_t tab = 0;
    std::uint64_t pane = 0;
    bool operator==(const LoginPane&) const = default;
  };

  struct LoginLink {
    Text url;
    ds::Option<Text> code;
  };

  tbc::val_a<ds::Option<LoginLink>> findLoginLink(tbc::mut_a<Memory> memory, std::string_view text, const LoginPlan& plan) {
    std::string_view url;

    for (std::size_t start = 0;;) {
      const auto at = text.find("https://", start);
      if (at == std::string_view::npos) {
        return ds::none;
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
      } catch (const std::exception&) {
        continue;
      }

      const auto host = notificationLinkHost(candidate);
      if (std::ranges::any_of(plan.hosts, [&](auto known) {
            return asciiEqualIgnoreCase(host, known);
          })) {
        url = candidate;
        break;
      }
    }

    LoginLink result{.url = Text{memory, url}, .code = ds::none};

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
      const auto line = trimText(lines.substr(0, end), " \t\r");
      const auto word = line.substr(0, line.find_first_of(" \t\r"));
      if (!word.empty() && !word.starts_with('(')) {
        result.code = Text{memory, word};
        return result;
      }

      if (end == std::string_view::npos) {
        return result;
      }

      lines.remove_prefix(end + 1);
    }
  }

  class Logins {
    Memory& memory_;
    SetupReport& report_;
    const MachineProfile& profile_;
    const Platform& platform_;
    bool interactive_;
    static constexpr auto status_timeout = std::chrono::seconds{30};
    static constexpr auto link_timeout = std::chrono::seconds{60};
    static constexpr auto finish_timeout = std::chrono::minutes{15};
    static constexpr auto poll_interval = std::chrono::milliseconds{500};
    static constexpr auto status_interval = std::chrono::seconds{3};
    static constexpr std::string_view records = "$HOME/.local/state/telar/setup-logins";

    static tbc::val_a<JsonValue> required(tbc::val_a<JsonValue> value, std::string_view name) {
      const auto field = value.field(name);
      if (!field) {
        throw CommandError{"LoginPaneUnreadable"};
      }

      return *field;
    }

    static std::uint64_t number(JsonValue value) {
      const auto result = parseExact<std::uint64_t>(value.encoded());
      if (!result) {
        throw CommandError{"LoginPaneUnreadable"};
      }

      return *result;
    }

    Text string(JsonValue value) {
      Text result{memory_};

      value.string(result);
      return result;
    }

    static LoginPane pane(JsonValue value) {
      return {number(required(value, "workspace_id")), number(required(value, "tab_id")), number(required(value, "pane_id"))};
    }

    Text capture(std::span<const std::string_view> words, ds::Option<std::string_view> input = ds::none) {
      // The same encoded command, length limit included, as every dispatch.
      const auto command = remoteCommand(memory_, profile_, words);
      auto output = launch::capture(memory_, ssh(memory_, profile_.destination(), command).view(), input.valueOr(std::string_view{}), status_timeout);

      std::fwrite(output.err.data(), 1, output.err.size(), stderr);
      if (output.status != 0) {
        throw CommandError{"MachineCommandFailed"};
      }

      static_cast<void>(whole(output));
      return std::move(output.out);
    }

    Text capture(std::initializer_list<std::string_view> words, ds::Option<std::string_view> input = ds::none) {
      return capture(std::span<const std::string_view>{words.begin(), words.size()}, input);
    }

    launch::Output script(std::string_view bytes) {
      return runScript(memory_, profile_.destination(), bytes, status_timeout);
    }

    ds::Option<Text> command(std::initializer_list<std::string_view> words, bool missing_pane) {
      Text bytes{memory_, "exec "};

      launch::appendQuoted(bytes, profile_.program().valueOr("telar"));
      for (const auto word : words) {
        bytes.push(' ');
        launch::appendQuoted(bytes, word);
      }

      bytes.push('\n');
      auto output = script(bytes);
      auto diagnostic = output.err.view();

      while (diagnostic.ends_with('\n') || diagnostic.ends_with('\r')) {
        diagnostic.remove_suffix(1);
      }

      const bool missing = output.out.empty() && (missing_pane ? output.status == 2 && diagnostic == "telar pane: pane not found or its generation is stale" : output.status == 1 && (diagnostic == "telar tab: tab not found" || diagnostic == "telar tab: workspace not found"));
      if (missing) {
        return ds::none;
      }

      std::fwrite(output.err.data(), 1, output.err.size(), stderr);
      if (output.status == launch::ssh_failure) {
        throw CommandError{"SshFailed"};
      }

      if (output.status != 0) {
        throw CommandError{"MachineCommandFailed"};
      }

      static_cast<void>(whole(output));
      return std::move(output.out);
    }

    Text recordPath(std::string_view agent) {
      return ds::format(memory_, "{}/{}", records, agent);
    }

    void forget(std::string_view agent) {
      if (script(ds::format(memory_, "rm -f \"{}\"\n", recordPath(agent))).status != 0) {
        throw CommandError{"LoginRecordUnwritable"};
      }
    }

    void remember(std::string_view agent, LoginPane pane) {
      const auto bytes = ds::format(memory_, "umask 077 && mkdir -p \"{}\" && printf '%s\\n' '{} {} {}' > \"{}\"\n", records, pane.workspace, pane.tab, pane.pane, recordPath(agent));
      if (script(bytes).status != 0) {
        throw CommandError{"LoginRecordUnwritable"};
      }
    }

    // The pane a record holds: three numbers and nothing else.
    static ds::Option<LoginPane> parseRecord(std::string_view text) {
      ds::Array<std::uint64_t, 3> numbers{};
      std::size_t count = 0;

      for (;;) {
        text = trimText(text, " \t\r\n");
        if (text.empty()) {
          break;
        }

        const auto end = std::min(text.find_first_of(" \t\r\n"), text.size());
        const auto value = parseExact<std::uint64_t>(text.substr(0, end));
        if (!value || count == numbers.size()) {
          return ds::none;
        }

        numbers.atMut(count++) = *value;
        text.remove_prefix(end);
      }

      if (count != numbers.size()) {
        return ds::none;
      }

      return LoginPane{.workspace = numbers[0], .tab = numbers[1], .pane = numbers[2]};
    }

    ds::Option<LoginPane> find(std::string_view agent, std::string_view title) {
      const auto output = script(ds::format(memory_, "cat \"{}\" 2>/dev/null || true\n", recordPath(agent)));
      if (output.status != 0) {
        throw CommandError{"LoginRecordUnreadable"};
      }

      const auto record = parseRecord(whole(output));
      if (!record) {
        return ds::none;
      }

      const auto noted = *record;
      const auto workspaces = capture({"workspace", "list", "--json"});
      bool named = false;

      JsonValue::parse(workspaces).eachElement([&](JsonValue value) {
        if (number(required(value, "workspace_id")) == noted.workspace && string(required(value, "name")) == title) {
          named = true;
        }
      });

      if (!named) {
        forget(agent);
        return ds::none;
      }

      const auto tab = command({"tab", "get", decimal(noted.tab).view(), "--workspace", decimal(noted.workspace).view(), "--json"}, false);
      if (tab) {
        const auto parsed = JsonValue::parse(*tab);
        if (number(required(parsed, "workspace_id")) != noted.workspace || number(required(parsed, "tab_id")) != noted.tab) {
          throw CommandError{"LoginPaneUnreadable"};
        }

        bool found = false;

        required(parsed, "panes").eachElement([&](JsonValue value) {
          found = found || number(required(value, "pane_id")) == noted.pane;
        });

        if (found) {
          return noted;
        }
      }

      forget(agent);
      return ds::none;
    }

    void closeTab(LoginPane pane) {
      const auto output = command({"tab", "close", decimal(pane.tab).view(), "--workspace", decimal(pane.workspace).view(), "--json"}, false);
      if (!output) {
        return;
      }

      const auto value = JsonValue::parse(*output);
      if (number(required(value, "workspace_id")) != pane.workspace || number(required(value, "tab_id")) != pane.tab || required(value, "closed").encoded() != "true") {
        throw CommandError{"LoginPaneUnreadable"};
      }
    }

    void close(std::string_view agent, LoginPane pane, const LoginPlan& plan) {
      const auto current = find(agent, plan.title);
      if (!current || *current != pane) {
        return;
      }

      closeTab(pane);
      forget(agent);
    }

    LoginPane open(std::string_view agent, std::string_view path, const LoginPlan& plan) {
      ds::Vec<std::string_view, Memory> words{memory_};

      words.extend(ds::Array<std::string_view, 10>{"workspace", "create", "--directory", platform_.home, "--name", plan.title, "--columns", "1024", "--json", "--"}.view());
      if (plan.environment) {
        words.push("/usr/bin/env");
        words.push(*plan.environment);
      }

      words.push(path);
      words.extend(plan.arguments);
      const auto output = capture(words.view());
      LoginPane created;

      try {
        created = pane(JsonValue::parse(output));
      } catch (const std::exception&) {
        throw CommandError{"LoginPaneUnreadable"};
      }

      try {
        remember(agent, created);
      } catch (...) {
        try {
          closeTab(created);
        } catch (const std::exception&) {
        }

        throw;
      }

      return created;
    }

    ds::Option<Text> provider(std::string_view agent) {
      if (agent != "pi" && agent != "opencode") {
        return ds::none;
      }

      const auto* home = std::getenv("HOME");
      if (!home) {
        return ds::none;
      }

      static constexpr ds::Array<std::string_view, 1> pi_files{"settings.json"};
      static constexpr ds::Array<std::string_view, 2> opencode_files{"opencode.json", "opencode.jsonc"};
      const auto root = localRoot(memory_, agent, home);
      const auto filenames = agent == "pi" ? std::span<const std::string_view>{pi_files.view()} : std::span<const std::string_view>{opencode_files.view()};

      for (const auto name : filenames) {
        try {
          const auto path = ds::format(memory_, "{}/{}", root, name);
          const auto bytes = integration::read(memory_, path, launch::output_limit);
          if (!bytes) {
            continue;
          }

          const auto plain = filter::stripJsonc(memory_, *bytes);
          const auto parsed = JsonValue::parse(plain);
          if (!parsed.encoded().starts_with('{')) {
            return ds::none;
          }

          const auto field = parsed.field(agent == "pi" ? "defaultProvider" : "model");
          if (!field || !field->encoded().starts_with('"')) {
            continue;
          }

          auto value = string(*field);

          if (agent == "pi") {
            return std::move(value);
          }

          const auto slash = value.view().find('/');
          if (slash != std::string_view::npos) {
            return Text{memory_, value.view().substr(0, slash)};
          }
        } catch (const std::exception&) {
        }
      }

      return ds::none;
    }

    bool loggedIn(std::string_view agent, std::string_view path, ds::Option<std::string_view> provider) {
      std::string_view check;

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

      Text bytes{memory_};

      appendAssign(bytes, "agent", path);
      appendAssign(bytes, "provider", provider.valueOr(std::string_view{}));
      bytes.append(check);
      bytes.push('\n');
      const auto output = script(bytes);
      if (output.status == launch::ssh_failure) {
        throw CommandError{"SshFailed"};
      }

      return output.status == 0;
    }

    struct Read {
      ds::Option<int> exit_code;
      Text text;
    };

    ds::Option<Read> read(LoginPane pane) {
      const auto output = command({"pane", "read", decimal(pane.pane).view(), "--lines", "80", "--json"}, true);
      if (!output) {
        return ds::none;
      }

      try {
        const auto value = JsonValue::parse(*output);
        if (number(required(value, "pane_id")) != pane.pane) {
          throw CommandError{"LoginPaneUnreadable"};
        }

        const auto exit = required(value, "exit_code").encoded();
        ds::Option<int> code;

        if (exit != "null") {
          const auto parsed = parseExact<int>(exit);
          if (!parsed) {
            throw CommandError{"LoginPaneUnreadable"};
          }

          code = parsed;
        }

        return Read{.exit_code = code, .text = string(required(value, "text"))};
      } catch (const std::exception&) {
        throw CommandError{"LoginPaneUnreadable"};
      }
    }

    ds::Option<MachineLogin> ended(std::string_view agent, std::string_view path, ds::Option<std::string_view> provider, const ds::Option<Read>& read, LoginPane pane) {
      if (read && !read->exit_code) {
        return ds::none;
      }

      const auto logged_in = loggedIn(agent, path, provider);
      if (logged_in && (!read || read->exit_code == 0)) {
        return MachineLogin::done;
      }

      if (read && read->exit_code) {
        report_.note(Step::logins, "{}: login command exited with {}; status is {}. Read its diagnostic with pane read {} --json on {}, then retry setup", agent, *read->exit_code, logged_in ? "logged in" : "not logged in", pane.pane, profile_.label());
      } else {
        report_.note(Step::logins, "{}: login pane disappeared before authentication completed; retry setup", agent);
      }

      return MachineLogin::failed;
    }

    bool announce(const LoginPlan& plan, const ds::Option<LoginLink>& found) {
      auto body = ds::format(memory_, "on {}: {}", profile_.label(), plan.instructions);

      if (found && found->code) {
        ds::formatTo(body, ". Code: {}", *found->code);
        if (body.size() > max_notification_message_bytes) {
          body = ds::format(memory_, "Code: {}, on {}: {}", *found->code, profile_.label(), plan.instructions);
        }
      }

      try {
        const RuntimePaths paths{memory_, ServerOptions{}, process_environment};
        ControlSession session{memory_, paths.socket.data()};

        session.receiveTimeout(static_cast<unsigned>(status_timeout.count()));
        const auto result = session.template exchange<NotificationShown>(ShowNotification{.notification = {.duration_ms = max_notification_duration_ms, .title = utf8Prefix(plan.title, max_notification_title_bytes), .message = utf8Prefix(body, max_notification_message_bytes), .link = found ? found->url.view() : std::string_view{}}});

        return result.delivered_clients != 0;
      } catch (const std::exception&) {
        return false;
      }
    }

    void send(LoginPane pane, std::string_view text) {
      capture({"pane", "send-keys", decimal(pane.pane).view(), "--stdin", "--enter"}, text);
    }

    struct Request {
      std::string_view agent;
      std::string_view path;
      ds::Option<std::string_view> provider;
      LoginPlan plan;
    };

    MachineLogin loginOne(const Request& request) {
      const auto agent = request.agent;
      const auto path = request.path;
      const auto provider = request.provider;
      const auto& plan = request.plan;
      const auto existing = find(agent, plan.title);
      const auto pane = existing ? *existing : open(agent, path, plan);

      try {
        if (existing) {
          report_.progress("{} on {}: the login setup started before is still open there", plan.title, profile_.label());
        } else if (plan.keys) {
          send(pane, *plan.keys);
        }

        if (plan.link) {
          const auto deadline = std::chrono::steady_clock::now() + link_timeout;
          ds::Option<LoginLink> found;

          while (std::chrono::steady_clock::now() < deadline) {
            const auto value = read(pane);
            if (const auto result = ended(agent, path, provider, value, pane)) {
              close(agent, pane, plan);
              return *result;
            }

            found = findLoginLink(memory_, value->text, plan);
            if (found && (!plan.code_marker || found->code)) {
              break;
            }

            found.reset();
            std::this_thread::sleep_for(poll_interval);
          }

          if (!found) {
            report_.progress("{}: no login link appeared in its pane on {}; finish it there", agent, profile_.label());
            return MachineLogin::pending;
          }

          report_.progress("{} on {}: {}", plan.title, profile_.label(), found->url);
          if (found->code) {
            report_.progress("one-time code: {}", *found->code);
          }

          if (!announce(plan, found)) {
            report_.progress("no window here took the notification; open the link above");
          }
        } else {
          announce(plan, ds::none);
          report_.progress("{} on {}: {}", plan.title, profile_.label(), plan.instructions);
        }

        if (!interactive_) {
          if (const auto result = ended(agent, path, provider, read(pane), pane)) {
            close(agent, pane, plan);
            return *result;
          }

          return MachineLogin::pending;
        }

        if (plan.paste) {
          std::printf("Paste %.*s for %.*s (Enter to finish in the pane instead): ", static_cast<int>(plan.paste->size()), plan.paste->data(), static_cast<int>(agent.size()), agent.data());
          std::fflush(stdout);
          ds::Array<char, max_notification_message_bytes * 8> answer{};
          if (std::cin.getline(answer.dataMut(), answer.size())) {
            const auto text = trimText(std::string_view{answer.data()}, " \r\t");
            if (!text.empty()) {
              send(pane, text);
            }
          } else if (!std::cin.eof()) {
            // A paste too long to be a code: the rest of its line is dropped with it.
            std::cin.clear();
            std::cin.ignore(std::numeric_limits<std::streamsize>::max(), '\n');
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

        report_.note(Step::logins, "{}: authentication did not complete before the login timeout; retry setup", agent);
        close(agent, pane, plan);
        return MachineLogin::failed;
      } catch (...) {
        try {
          close(agent, pane, plan);
        } catch (const std::exception&) {
        }

        throw;
      }
    }

  public:
    Logins(Memory& memory, SetupReport& report, const MachineProfile& profile, const Platform& platform, bool interactive)
        : memory_(memory),
          report_(report),
          profile_(profile),
          platform_(platform),
          interactive_(interactive) {}

    void run(AgentSet wanted, std::string_view profiles_path) {
      // Each agent's outcome, by its place in agent_names.
      ds::Array<ds::Option<MachineLogin>, agent_names.size()> results{};
      bool started = false;

      for (std::size_t index = 0; index < agent_names.size(); ++index) {
        const auto agent = agent_names[index];
        if (!wanted.contains(agent) || !platform_.agents.contains(agent)) {
          continue;
        }

        auto& result = results.atMut(index);
        const auto path = platform_.agents.find(agent)->view();
        const auto selected = provider(agent);
        const auto chosen = selected ? ds::Option{selected->view()} : ds::none;
        bool logged_in = false;

        try {
          logged_in = loggedIn(agent, path, chosen);
        } catch (const std::exception& error) {
          report_.note(Step::logins, "{}: its login status could not be read there: {}", agent, error.what());
          result = MachineLogin::failed;
          continue;
        }

        const auto plan = planFor(agent, chosen);

        if (logged_in) {
          try {
            if (plan) {
              if (const auto pane = find(agent, plan->title)) {
                close(agent, *pane, *plan);
              }
            }
          } catch (const std::exception& error) {
            report_.note(Step::logins, "{}: its login cleanup failed: {}", agent, error.what());
            result = MachineLogin::failed;
            continue;
          }

          result = MachineLogin::done;
          report_.note(Step::logins, "{}: logged in", agent);
        } else if (!plan) {
          report_.note(Step::logins, "{}: log in there yourself; setup has no browser login for {}", agent, chosen.valueOr("its provider"));
        } else {
          started = true;
          try {
            result = loginOne({agent, path, chosen, *plan});
          } catch (const std::exception& error) {
            report_.note(Step::logins, "{}: {}", agent, error.what());
            result = MachineLogin::failed;
          }

          if (*result != MachineLogin::failed) {
            report_.note(Step::logins, "{}: {}", agent, machine_login_names[static_cast<std::size_t>(*result)]);
          }
        }
      }

      const bool any = std::ranges::any_of(results, [](const auto& entry) {
        return entry.hasValue();
      });

      try {
        if (any) {
          update(memory_, profiles_path, [&](MachineProfiles& profiles) {
            for (std::size_t index = 0; index < results.size(); ++index) {
              if (results[index]) {
                const auto found = std::ranges::find(machine_agent_names, agent_names[index]);

                profiles.recordLogin(profile_.label(), static_cast<MachineAgent>(found - machine_agent_names.begin()), *results[index]);
              }
            }
          });
        }
      } catch (const std::exception& error) {
        const auto* text = describe(error.what());

        report_.note(Step::logins, "machines.json keeps the logins it had: {}", text ? text : error.what());
      }

      const auto has = [&](MachineLogin outcome) {
        return std::ranges::any_of(results, [&](const auto& entry) {
          return entry == ds::Option{outcome};
        });
      };

      const bool failed = has(MachineLogin::failed);
      const bool pending = has(MachineLogin::pending);
      const auto status = failed ? Status::failed : !any  ? Status::skipped
                                                : pending ? Status::pending
                                                : started ? Status::changed
                                                          : Status::ok;

      report_.end(Step::logins, status, "{}", failed ? "a login failed; see the notes" : !any  ? "no agent there to log in"
                                                                                     : pending ? "a login waits for you; run setup again to see it done"
                                                                                     : started ? "every started login finished"
                                                                                               : "every agent there is logged in");
    }
  };

  tbc::val_a<Target> resolve(tbc::mut_a<Memory> memory, const MachineProfiles& profiles, const MachineOptions& options) {
    for (const auto& profile : profiles.rows()) {
      if (profile.label() == options.label || profile.destination() == options.label) {
        return {.label = Text{memory, profile.label()}, .destination = Text{memory, profile.destination()}, .saved = profile};
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
    Text label{memory, host.substr(0, MachineLimits::label_bytes)};

    for (auto& byte : label.viewMut()) {
      if (!((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '.' || byte == '_' || byte == '-')) {
        byte = '-';
      }
    }

    if (options.new_label) {
      label.assign(*options.new_label);
    }

    try {
      MachineFieldRules::label(label);
    } catch (const MachineFailure&) {
      if (!options.new_label) {
        throw CommandError{"MachineLabelNeeded"};
      }

      throw;
    }

    MachineOptions trial{.action = MachineOptions::Action::add, .label = label, .value = options.label};
    auto copy = profiles;

    change(copy, trial);
    return {.label = std::move(label), .destination = Text{memory, options.label}, .saved = ds::none};
  }

  // A file's SHA-256, as 64 lowercase hexadecimal digits.
  using Digest = FixedText<SHA256_DIGEST_LENGTH * 2>;

  Digest fileDigest(const char* path) {
    FileDescriptor file{::open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)};
    struct stat state{};
    if (!file || ::fstat(file.get(), &state) != 0 || !S_ISREG(state.st_mode)) {
      throw CommandError{"SetupBinaryUnreadable"};
    }

    Sha256 digest;
    ds::Array<std::uint8_t, 64 * 1024> buffer;

    for (;;) {
      const auto count = ::read(file.get(), buffer.dataMut(), buffer.size());
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (count < 0) {
        throw CommandError{"SetupBinaryUnreadable"};
      }

      if (count == 0) {
        break;
      }

      digest.update({reinterpret_cast<const char*>(buffer.data()), static_cast<std::size_t>(count)});
    }

    const auto bytes = digest.finish();
    ds::Array<char, SHA256_DIGEST_LENGTH * 2> digits;
    Digest text;

    text.assign(encodeLowerHex(bytes, digits.viewMut()));
    return text;
  }

  // The directory a path names a file in.
  std::string_view parentOf(std::string_view path) {
    const auto slash = path.rfind('/');

    return slash == std::string_view::npos ? std::string_view{"."} : path.substr(0, slash == 0 ? 1 : slash);
  }

  tbc::val_a<ds::Option<Platform>> reach(tbc::mut_a<Memory> memory, SetupReport& report, const Target& target, std::string_view directory) {
    launch::Output probe{memory};
    bool confirmed = false;
    const auto run = [&] {
      Text script{memory};

      appendAssign(script, "dir", directory);
      script.append(assets::probe);
      return runScript(memory, target.destination, script);
    };

    try {
      probe = run();
      const auto failure = sshFailure(probe);
      if (probe.status != 0 && !report.json && ::isatty(STDIN_FILENO) && (failure == MachineError::host_key_rejected || failure == MachineError::authentication_failed)) {
        std::printf("Batch-mode SSH to %s was refused. Connecting once with your terminal: OpenSSH asks, you answer; telar accepts nothing for you.\n", target.destination.data());
        std::fflush(stdout);
        confirmed = launch::inherit(launch::words(memory, {"ssh", "-o", "ControlPath=none", "-o", "ForwardAgent=no", "--", target.destination, "true"}).view()) == 0;
        if (confirmed) {
          probe = run();
        }
      }
    } catch (const std::exception& error) {
      report.end(Step::ssh, Status::failed, "ssh did not run to the end: {}", error.what());
      return ds::none;
    }

    if (probe.status != 0) {
      const auto failure = sshFailure(probe);
      if (probe.status != launch::ssh_failure && failure != MachineError::remote_runtime_incompatible) {
        report.end(Step::ssh, Status::ok, "batch-mode SSH to {} works", target.destination);
        report.end(Step::platform, Status::failed, "the probe failed there: {}", probe.errorLine());
      } else if (failure == MachineError::authentication_failed) {
        if (confirmed) {
          report.end(Step::ssh, Status::failed, "{} accepts your login only interactively; windows need a key. Run `ssh-copy-id {}`, then setup again", target.destination, target.destination);
        } else {
          report.end(Step::ssh, Status::failed, "{} refused the login in batch mode; add a key with `ssh-copy-id {}` or run setup from a terminal", target.destination, target.destination);
        }
      } else if (failure == MachineError::host_key_rejected) {
        report.end(Step::ssh, Status::failed, "the host key of {} is not confirmed: {}", target.destination, probe.errorLine());
      } else {
        report.end(Step::ssh, Status::failed, "{}", probe.errorLine());
      }

      return ds::none;
    }

    report.end(Step::ssh, confirmed ? Status::changed : Status::ok, "batch-mode SSH to {} works", target.destination);
    try {
      auto platform = Platform::parse(memory, whole(probe));

      report.end(Step::platform, Status::ok, "{} {}{}, {}", platform.os == "linux" ? "Linux" : "macOS", platform.arch, platform.libc == "musl" ? " (musl)" : "", platform.assetName(memory));
      return std::move(platform);
    } catch (const std::exception& error) {
      report.end(Step::platform, Status::failed, "{}: {}", error.what(), probe.out.view().substr(0, probe.out.view().find('\n')));
      return ds::none;
    }
  }

  struct Install {
    // The --binary path, which views the command line.
    ds::Option<std::string_view> binary;
    ds::Option<Digest> digest;
    Text directory;
  };

  std::string_view releasesUrl() {
    const auto* configured = std::getenv("TELAR_RELEASES_URL");

    return configured && *configured ? std::string_view{configured} : std::string_view{"https://github.com/adriangs1996/telar/releases"};
  }

  Digest releaseDigest(Memory& memory, std::string_view asset) {
    const auto url = ds::format(memory, "{}/download/v{}/SHA256SUMS", releasesUrl(), version);
    constexpr std::size_t max_url_bytes = 2048;
    if (url.size() >= max_url_bytes) {
      throw CommandError{"ReleaseUrlTooLong"};
    }

    launch::Output output{memory};

    try {
      output = launch::capture(memory, launch::words(memory, {"curl", "--proto", "=https,file", "--tlsv1.2", "-fsSL", "--", url}).view(), {}, probe_timeout);
    } catch (const std::exception&) {
      throw CommandError{"ReleaseUnavailable"};
    }

    constexpr std::size_t max_sums_bytes = 64 * 1024;
    if (output.status != 0 || output.dropped != 0 || output.out.size() > max_sums_bytes) {
      throw CommandError{"ReleaseUnavailable"};
    }

    auto lines = output.out.view();

    while (!lines.empty()) {
      const auto end = std::min(lines.find('\n'), lines.size());
      auto words = trimText(lines.substr(0, end), " \t\r");

      lines.remove_prefix(std::min(end + 1, lines.size()));
      const auto split = words.find_first_of(" \t");
      if (split == std::string_view::npos) {
        continue;
      }

      const auto digest = words.substr(0, split);
      auto name = trimText(words.substr(split), " \t");

      name = name.substr(0, name.find_first_of(" \t"));
      if (name.starts_with('*')) {
        name.remove_prefix(1);
      }

      if (name != asset) {
        continue;
      }

      constexpr std::size_t digest_hex_bytes = SHA256_DIGEST_LENGTH * 2;
      if (digest.size() != digest_hex_bytes || !std::ranges::all_of(digest, [](unsigned char byte) {
            return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F');
          })) {
        throw CommandError{"ReleaseDigestUnreadable"};
      }

      ds::Array<char, digest_hex_bytes> lowered;
      Digest text;

      std::format_to(lowered.dataMut(), "{}", AsciiLower{digest});
      text.assign({lowered.data(), lowered.size()});
      return text;
    }

    throw CommandError{"ReleaseAssetMissing"};
  }

  ds::Option<bool> installRuntime(Memory& memory, SetupReport& report, const Target& target, const Platform& platform, const Install& build) {
    if (!build.binary) {
      return false;
    }

    bool changed = false;

    for (const std::string_view tool : {"telar-runtime", "telar-config-check"}) {
      const auto sibling = ds::format(memory, "{}/{}", parentOf(*build.binary), tool);
      if (::access(sibling.data(), R_OK) != 0) {
        continue;
      }

      try {
        const auto digest = fileDigest(sibling.data());
        const auto remote = ds::format(memory, "{}/{}", platform.binDirectory(), tool);
        static constexpr std::string_view hasher = R"Hash(hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}
)Hash";
        Text check{memory};

        appendAssign(check, "target", remote);
        appendAssign(check, "expected", digest.view());
        ds::formatTo(check, "{}[ -f \"$target\" ] && [ \"$(hash \"$target\")\" = \"$expected\" ]\n", hasher);
        const auto inspect = runScript(memory, target.destination, check);
        if (inspect.status == 0) {
          continue;
        }

        if (inspect.status == launch::ssh_failure) {
          throw CommandError{"SshFailed"};
        }

        FileDescriptor runtime{::open(sibling.data(), O_RDONLY | O_CLOEXEC)};
        if (!runtime) {
          throw fileError(sys::lastError());
        }

        Text script{memory};

        appendAssign(script, "target", remote);
        appendAssign(script, "expected", digest.view());
        script.append(hasher);
        script.append(R"Upload(umask 077
temporary=$target.upload.$$
trap 'rm -f "$temporary"' EXIT
cat > "$temporary" && [ "$(hash "$temporary")" = "$expected" ] && chmod 755 "$temporary" && mv -f "$temporary" "$target"
)Upload");
        Text command{memory, "exec /bin/sh -c "};

        launch::appendQuoted(command, script);
        const auto uploaded = launch::captureFile(memory, ssh(memory, target.destination, command).view(), runtime.get(), install_timeout);
        if (uploaded.status != 0) {
          report.end(Step::telar, Status::failed, "the runtime upload failed: {}", uploaded.errorLine());
          return ds::none;
        }

        changed = true;
      } catch (const std::exception& error) {
        report.end(Step::telar, Status::failed, "the runtime upload did not run to the end: {}", error.what());
        return ds::none;
      }
    }

    return changed;
  }

  tbc::val_a<bool> install(tbc::mut_a<Memory> memory, SetupReport& report, const Target& target, const Platform& platform, const Install& build) {
    try {
      MachineFieldRules::program(platform.target);
    } catch (const MachineFailure&) {
      report.end(Step::telar, Status::failed, "{} holds a character a remote command cannot carry unquoted; telar needs a home of letters, digits and /._+-", platform.target);
      return false;
    }

    if (platform.installed && *platform.installed == ds::format(memory, "telar {}", version).view()) {
      const auto runtime = installRuntime(memory, report, target, platform, build);
      if (!runtime) {
        return false;
      }

      report.end(Step::telar, *runtime ? Status::changed : Status::ok, "{}telar {} at {}", *runtime ? "installed " : "", version, platform.target);
      return true;
    }

    Text script{memory};

    if (build.binary) {
      const auto short_digest = build.digest->view().substr(0, MachineId::hex_digits);
      const auto upload_command = ds::format(memory, "exec /bin/sh -c 'umask 077 && mkdir -p \"$HOME/.local/share/telar/versions\" && exec cat > \"$HOME/.local/share/telar/versions/.upload-{}\"'", short_digest);
      const Text binary_path{memory, *build.binary};
      FileDescriptor binary{::open(binary_path.data(), O_RDONLY | O_CLOEXEC)};
      if (!binary) {
        report.end(Step::telar, Status::failed, "{}: cannot open --binary", fileError(sys::lastError()).what());
        return false;
      }

      try {
        const auto uploaded = launch::captureFile(memory, ssh(memory, target.destination, upload_command).view(), binary.get(), install_timeout);
        if (uploaded.status != 0) {
          report.end(Step::telar, Status::failed, "the upload failed: {}", uploaded.errorLine());
          return false;
        }
      } catch (const std::exception& error) {
        report.end(Step::telar, Status::failed, "the upload did not run to the end: {}", error.what());
        return false;
      }

      ds::formatTo(script, "upload=$HOME/.local/share/telar/versions/.upload-{}\n", short_digest);
      appendAssign(script, "digest", build.digest->view());
      appendAssign(script, "bin_dir", platform.binDirectory());
      script.append("(\nset -- --binary \"$upload\" --sha256 \"$digest\" --bin-dir \"$bin_dir\"\n");
    } else {
      if (version == "0.0.0") {
        report.end(Step::telar, Status::failed, "this is a development build ({}) with no release to download; pass --binary with a telar built for {} {}", version, platform.os, platform.arch);
        return false;
      }

      if (!platform.has("curl")) {
        report.end(Step::telar, Status::failed, "{} has no curl, which the installer needs to download the release; install curl there, or pass --binary", target.label);
        return false;
      }

      const auto asset = platform.assetName(memory);
      Digest digest;

      try {
        digest = releaseDigest(memory, asset);
      } catch (const std::exception& error) {
        report.end(Step::telar, Status::failed, "{}: cannot read the hash of {} from release {} at {}", error.what(), asset, version, releasesUrl());
        return false;
      }

      appendAssign(script, "upload", "");
      appendAssign(script, "digest", digest.view());
      appendAssign(script, "version", version);
      appendAssign(script, "bin_dir", platform.binDirectory());
      if (const auto* url = std::getenv("TELAR_RELEASES_URL")) {
        appendAssign(script, "TELAR_RELEASES_URL", url);
        script.append("export TELAR_RELEASES_URL\n");
      }

      script.append("(\nset -- --version \"$version\" --sha256 \"$digest\" --bin-dir \"$bin_dir\"");
      if (platform.os == "linux") {
        script.append(" --headless");
      }

      script.push('\n');
    }

    script.append(assets::installer);
    script.append("\n)\nstatus=$?\nif [ -n \"$upload\" ]; then rm -f \"$upload\"; fi\nexit $status\n");
    try {
      const auto output = runScript(memory, target.destination, script, install_timeout);
      if (output.status != 0) {
        report.end(Step::telar, Status::failed, "the installer refused: {}", output.errorLine());
        return false;
      }
    } catch (const std::exception& error) {
      report.end(Step::telar, Status::failed, "the installer did not run to the end: {}", error.what());
      return false;
    }

    if (!installRuntime(memory, report, target, platform, build)) {
      return false;
    }

    report.end(Step::telar, Status::changed, "installed telar {} at {}", version, platform.target);
    return true;
  }

  std::string_view schemaText(const SchemaId& schema) {
    return {reinterpret_cast<const char*>(schema.data()), schema.size()};
  }

  bool startRuntime(Memory& memory, SetupReport& report, const Target& target, const MachineProfile& remote, bool interactive) {
    const auto program = *remote.program();
    Text detail{memory};

    try {
      const auto found = discover(memory, remote, detail);
      if (!found.compatible()) {
        report.end(Step::runtime, Status::failed, "the telar at {} speaks wire schema {}, this one {}; pass a --binary built from this tree", program, schemaText(found.schema()), schemaText(handshake::schema_id));
        return false;
      }

      report.end(Step::runtime, Status::ok, "running at {}", found.endpoint());
      return true;
    } catch (const MachineFailure& error) {
      if (error.code() != MachineError::remote_runtime_incompatible) {
        report.end(Step::runtime, Status::failed, "{}: {}", error.what(), trimText(detail, " \t\r\n"));
        return false;
      }
    }

    bool agreed = false;

    if (interactive) {
      std::printf("A telar runtime of another build runs on %s. Stopping it ends every pane and agent it runs. Stop it now? [y/N] ", target.label.data());
      std::fflush(stdout);
      agreed = answeredYes();
    }

    if (!agreed) {
      report.end(Step::runtime, Status::failed, "a runtime of another telar build runs there and keeps its panes; this build cannot attach until it stops. Run setup again from a terminal and agree to stop it");
      return false;
    }

    Text script{memory};

    appendAssign(script, "target", program);
    appendAssign(script, "stopping", "is stopping");
    script.append(R"Stop(for candidate in "$HOME/.local/bin/telar" "$HOME"/.local/share/telar/versions/*/telar $(command -v telar 2>/dev/null); do
    [ -x "$candidate" ] && [ "$candidate" != "$target" ] || continue
    if "$candidate" server stop 2>/dev/null | grep -q "$stopping"; then
        exit 0
    fi
done
echo 'no telar there could stop the running runtime' >&2
exit 1
)Stop");

    try {
      const auto stopped = runScript(memory, target.destination, script);
      if (stopped.status != 0) {
        report.end(Step::runtime, Status::failed, "{}", stopped.errorLine());
        return false;
      }
    } catch (const std::exception& error) {
      report.end(Step::runtime, Status::failed, "stopping the old runtime did not run to the end: {}", error.what());
      return false;
    }

    constexpr unsigned restart_attempts = 20;
    constexpr auto restart_wait = std::chrono::milliseconds{250};

    for (unsigned attempt = 0; attempt < restart_attempts; ++attempt) {
      try {
        const auto found = discover(memory, remote, detail);
        if (found.compatible()) {
          report.end(Step::runtime, Status::changed, "stopped the runtime of another build; this one runs at {}", found.endpoint());
          return true;
        }
      } catch (const MachineFailure&) {
      }

      std::this_thread::sleep_for(restart_wait);
    }

    report.end(Step::runtime, Status::failed, "the old runtime stopped but this build's did not answer");
    return false;
  }

  int setup(Memory& memory, const MachineOptions& options) {
    SetupReport report{memory, options.json};
    const auto path = profilesPath(memory);
    const auto profiles = load(memory, path);
    ds::Option<Target> resolved;
    Install build{.binary = ds::none, .digest = ds::none, .directory = Text{memory}};

    try {
      resolved = resolve(memory, profiles, options);
      build.directory.assign(version);
      if (options.binary) {
        build.binary = *options.binary;
        const Text binary{memory, *options.binary};

        build.digest = fileDigest(binary.data());
        ds::formatTo(build.directory, "-{}", build.digest->view().substr(0, MachineId::hex_digits));
        for (const std::string_view tool : {"telar-runtime", "telar-config-check"}) {
          const auto companion = ds::format(memory, "{}/{}", parentOf(*options.binary), tool);
          if (::access(companion.data(), R_OK) != 0) {
            throw CommandError{"SetupBinaryCompanionsMissing"};
          }

          ds::formatTo(build.directory, "-{}", fileDigest(companion.data()).view().substr(0, MachineId::hex_digits));
        }
      }
    } catch (const std::exception& error) {
      if (std::string_view{error.what()} == "DuplicateMachineLabel") {
        std::fprintf(stderr, "telar machine setup: the label for %.*s is taken by another machine; name it with --label\n", static_cast<int>(options.label.size()), options.label.data());
      } else {
        const auto* detail = describe(error.what());

        std::fprintf(stderr, "telar machine setup: %s\n", detail ? detail : error.what());
      }

      return 1;
    }

    const auto& target = *resolved;

    if (!options.json) {
      std::printf("Setting up %s (%s) with telar %.*s\n", target.label.data(), target.destination.data(), static_cast<int>(version.size()), version.data());
      std::fflush(stdout);
    }

    const bool interactive = !options.json && ::isatty(STDIN_FILENO);

    if (options.confirm) {
      if (!interactive) {
        return report.refuse(memory, target.label, target.destination, "--confirm needs a terminal to ask on; nothing was changed");
      }

      std::printf("This installs telar %.*s on %s (%s), and the agents you have here with their official installers; it copies their configuration, never a credential, and opens their logins there. Set it up? [y/N] ", static_cast<int>(version.size()), version.data(), target.label.data(), target.destination.data());
      std::fflush(stdout);
      if (!answeredYes()) {
        std::printf("Nothing was changed on %s.\n", target.label.data());
        return 0;
      }
    }

    const auto platform = reach(memory, report, target, build.directory);
    if (!platform || !install(memory, report, target, *platform, build)) {
      return report.finish(memory, target.label, target.destination);
    }

    Random random;
    auto remote = MachineProfile::create(MachineId::generate(random), {.label = target.label, .destination = target.destination, .program = platform->target.view()});
    Text detail{memory};

    if (!startRuntime(memory, report, target, remote, interactive)) {
      return report.finish(memory, target.label, target.destination);
    }

    Text link_script{memory};

    appendAssign(link_script, "telar", platform->target);
    link_script.append(R"Link(link=$HOME/.local/bin/telar
if [ -L "$link" ] && [ "$(readlink "$link")" = "$telar" ]; then exit 0; fi
if [ -e "$link" ] && [ ! -L "$link" ]; then echo 'it is a file telar did not link, so it stays; remove it to let setup link it' >&2; exit 1; fi
mkdir -p "$HOME/.local/bin" && "$telar" cli install --dir "$HOME/.local/bin" >/dev/null && echo linked
)Link");
    const auto link = runScript(memory, target.destination, link_script);
    if (link.status != 0) {
      report.note(Step::runtime, "~/.local/bin/telar left as it was: {}", link.errorLine());
    } else if (link.out.view().contains("linked")) {
      report.note(Step::runtime, "~/.local/bin/telar now links to {}", platform->target);
    }

    try {
      const auto previous = target.saved ? target.saved->program() : ds::none;
      const bool changed = !target.saved || previous != ds::Option{platform->target.view()} || (!target.saved->enabled() && !options.disabled);
      if (changed) {
        update(memory, path, [&](MachineProfiles& saved) {
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
      const std::string_view state = enabled ? "enabled" : "disabled, as asked";

      if (changed) {
        report.end(Step::profile, Status::changed, "{} {}, {}, telar at {}", target.label, target.saved ? "updated" : "saved", state, platform->target);
      } else {
        report.end(Step::profile, Status::ok, "{} is saved, {} and names {}", target.label, state, platform->target);
      }
    } catch (const std::exception& error) {
      const auto* description = describe(error.what());

      report.end(Step::profile, Status::failed, "{}", description ? description : error.what());
    }

    const auto wanted = localAgents(memory);
    ds::Option<Platform> reprobed;

    if (options.skip[0]) {
      report.end(Step::agents, Status::skipped, "--skip agents");
    } else if (installAgents(memory, report, target.destination, *platform, wanted)) {
      try {
        Text probe_script{memory};

        appendAssign(probe_script, "dir", build.directory);
        probe_script.append(assets::probe);
        const auto probe = runScript(memory, target.destination, probe_script);
        if (probe.status == 0) {
          reprobed = Platform::parse(memory, whole(probe));
        }
      } catch (const std::exception&) {
      }
    }

    const auto& current = reprobed ? *reprobed : *platform;

    integrateAgents(memory, report, target.destination, current);
    if (options.skip[1]) {
      report.end(Step::configuration, Status::skipped, "--skip config");
    } else {
      syncConfig(memory, report, target.destination, current, wanted);
    }

    if (options.skip[2]) {
      report.end(Step::logins, Status::skipped, "--skip login");
    } else {
      ds::Option<MachineProfile> saved;

      try {
        const auto profiles_now = load(memory, path);
        if (const auto row = profiles_now.find(target.label); row && profiles_now.rows()[*row].destination() == target.destination.view()) {
          saved = profiles_now.rows()[*row];
        }
      } catch (const std::exception&) {
      }

      if (saved) {
        Logins logins{memory, report, *saved, current, interactive};

        logins.run(wanted, path);
      } else {
        report.end(Step::logins, Status::skipped, "{} is not saved, so its logins cannot be recorded", target.label);
      }
    }

    try {
      const auto found = discover(memory, remote, detail);

      if (found.compatible()) {
        report.end(Step::check, Status::ok, "a window can attach: schema {} on both sides", schemaText(handshake::schema_id));
      } else {
        report.end(Step::check, Status::failed, "schema {} there, {} here", schemaText(found.schema()), schemaText(handshake::schema_id));
      }
    } catch (const MachineFailure& error) {
      report.end(Step::check, Status::failed, "{}: {}", error.what(), trimText(detail, " \t\r\n"));
    }

    return report.finish(memory, target.label, target.destination);
  }

}

namespace telar::runtime::cli {

  int runMachine(Memory& memory, const MachineOptions& options) {
    if (options.action == MachineOptions::Action::receive_config) {
      return config_receive::run(memory);
    }

    const auto path = machine::profilesPath(memory);

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

      machine::update(memory, path, [&](machines::MachineProfiles& saved) {
        machine::change(saved, options);
      });

      if (options.action == MachineOptions::Action::add && options.setup) {
        return machine::setup(memory, options);
      }

      return 0;
    } catch (const std::exception& error) {
      return machine::report(error);
    }
  }

}
