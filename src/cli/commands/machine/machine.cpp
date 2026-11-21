module telar.cli.commands.machine;
import telar.platform.sha256;
import telar.sys.posix;

import telar.base.text;
import telar.base.text.utf8;
import telar.cli.console.command_error;
import telar.cli.session.control_session;
import telar.cli.session.server;
import telar.client;
import telar.tls;

import telar.tbc;
import telar.platform.fs;
import telar.cli.commands.plugin;
import telar.base.text.json;
import telar.cli.console.command_limit;
import telar.cli.commands.integration.settings;
import telar.cli.session.runtime_observer;
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

  namespace {

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
      constexpr mode_t shared_permissions = 0077;
      struct stat state{};
      if (!lock || ::fstat(lock.get(), &state) != 0 || !S_ISREG(state.st_mode) || state.st_uid != ::geteuid() || (state.st_mode & shared_permissions) != 0) {
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
    struct Platform { // NOLINT(bugprone-exception-escape): its implicit move assignment moves Texts, which allocate only between two allocators, and every text of a platform comes from the one memory
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

      [[nodiscard]] bool has(std::string_view tool) const {
        const auto* const found = std::ranges::find(tool_names, tool);

        return found != tool_names.end() && ((static_cast<unsigned>(tools) >> static_cast<unsigned>(found - tool_names.begin())) & 1U) != 0;
      }

      // The directory the telar binary sits in there.
      [[nodiscard]] std::string_view binDirectory() const {
        const auto slash = target.view().rfind('/');

        return target.view().substr(0, slash == 0 ? 1 : slash);
      }

      // The system the probe names, as telar names it.
      static tbc::val_static<std::string_view> systemName(std::string_view value) {
        if (value == "Linux") {
          return "linux";
        }

        if (value == "Darwin") {
          return "macos";
        }

        throw CommandError{"UnsupportedMachineSystem"};
      }

      // The architecture the probe names, as telar names it.
      static tbc::val_static<std::string_view> architectureName(std::string_view value) {
        if (value == "x86_64" || value == "amd64") {
          return "x86_64";
        }

        if (value == "aarch64" || value == "arm64") {
          return "aarch64";
        }

        throw CommandError{"UnsupportedMachineArchitecture"};
      }

      static tbc::val_static<std::string_view> libcName(std::string_view value) {
        if (value != "gnu" && value != "musl") {
          throw CommandError{"MachineProbeUnreadable"};
        }

        return value == "gnu" ? std::string_view{"gnu"} : std::string_view{"musl"};
      }

      static void addTool(Platform& result, std::string_view value) {
        const auto* const tool = std::ranges::find(tool_names, value);
        if (tool == tool_names.end()) {
          throw CommandError{"MachineProbeUnreadable"};
        }

        result.tools |= static_cast<std::uint8_t>(1U << static_cast<unsigned>(tool - tool_names.begin()));
      }

      // An agent's `name:/path` there.
      static void addAgent(tbc::mut_a<Memory> memory, tbc::mut_a<Platform> result, std::string_view value) {
        const auto colon = value.find(':');
        const auto* const agent = std::ranges::find(machine_agent_names, value.substr(0, colon));
        if (colon == std::string_view::npos || agent == machine_agent_names.end() || colon + 1 == value.size() || value[colon + 1] != '/') {
          throw CommandError{"MachineProbeUnreadable"};
        }

        // The key is the static name, so it outlives the probe's output.
        const auto index = static_cast<std::size_t>(agent - machine_agent_names.begin());

        static_cast<void>(result.agents.assign(machine_agent_names[index], Text{memory, value.substr(colon + 1)}));
      }

      static tbc::val_a<Text> absolute(tbc::mut_a<Memory> memory, std::string_view value) {
        if (value.empty() || value.front() != '/') {
          throw CommandError{"MachineProbeUnreadable"};
        }

        return Text{memory, value};
      }

      // One `key=value` line of the probe's output.
      static void read(tbc::mut_a<Memory> memory, tbc::mut_a<Platform> result, std::string_view line) {
        constexpr unsigned char first_printable = 0x20;
        constexpr unsigned char delete_byte = 0x7f;
        const auto equals = line.find('=');
        if (equals == std::string_view::npos) {
          throw CommandError{"MachineProbeUnreadable"};
        }

        const auto key = line.substr(0, equals);
        const auto value = line.substr(equals + 1);
        if (value.size() > MachineLimits::program_bytes || std::ranges::any_of(value, [](unsigned char byte) {
              return byte < first_printable || byte == delete_byte;
            })) {
          throw CommandError{"MachineProbeUnreadable"};
        }

        if (key == "os") {
          result.os = systemName(value);
        } else if (key == "arch") {
          result.arch = architectureName(value);
        } else if (key == "libc") {
          result.libc = libcName(value);
        } else if (key == "home") {
          result.home = absolute(memory, value);
        } else if (key == "target") {
          result.target = absolute(memory, value);
        } else if (key == "installed") {
          result.installed = Text{memory, value};
        } else if (key == "node") {
          result.node = Text{memory, value};
        } else if (key == "tool") {
          addTool(result, value);
        } else if (key == "agent") {
          addAgent(memory, result, value);
        } else {
          throw CommandError{"MachineProbeUnreadable"};
        }
      }

      static tbc::val_a<Platform> parse(tbc::mut_a<Memory> memory, std::string_view output) {
        constexpr std::size_t max_output = 8 * std::size_t{1024};
        if (output.size() > max_output) {
          throw CommandError{"MachineProbeUnreadable"};
        }

        Platform result{memory};

        while (output.ends_with('\n')) {
          output.remove_suffix(1);
        }

        for (;;) {
          const auto end = output.find('\n');

          read(memory, result, output.substr(0, end));
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

    // A shell variable and the value a script assigns it.
    struct Assignment {
      std::string_view name;
      std::string_view value;
    };

    // Appends the shell assignment `name='value'` and a newline.
    void appendAssign(Text& script, Assignment assignment) {
      script.append(assignment.name);
      script.push('=');
      launch::appendQuoted(script, assignment.value);
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
      // Room for a word of an answer and the end of its line; a longer line is no answer.
      constexpr std::size_t answer_bytes = 18;
      ds::Array<char, answer_bytes> answer{};
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

      [[nodiscard]] bool contains(std::string_view agent) const {
        const auto position = index(agent);

        return position < agent_names.size() && ((static_cast<unsigned>(bits) >> position) & 1U) != 0;
      }

      void insert(std::string_view agent) {
        if (const auto position = index(agent); position < agent_names.size()) {
          bits |= static_cast<std::uint8_t>(1U << position);
        }
      }

      [[nodiscard]] bool empty() const {
        return bits == 0;
      }

      [[nodiscard]] std::size_t size() const {
        return static_cast<std::size_t>(std::popcount(bits));
      }
    };

    AgentSet localAgents(Memory& memory) {
      AgentSet found;
      const auto* variable = std::getenv("PATH"); // NOLINT(concurrency-mt-unsafe): POSIX has no thread-safe read of the environment
      if (variable == nullptr) {
        return found;
      }

      // Copied out of the environment, as std::env::var does: a call into the project may change it.
      const Text path{memory, variable};

      ds::Array<char, PATH_MAX> executable{};

      for (std::size_t agent = 0; agent < agent_names.size(); ++agent) {
        if (findExecutable({.path = path.view(), .program = agent_commands[agent]}, executable.viewMut())) {
          found.insert(agent_names[agent]);
        }
      }

      return found;
    }

    constexpr std::size_t agent_names_bytes = 64;

    // The agents' names, comma-separated; every name together fits.
    FixedText<agent_names_bytes> names(AgentSet agents) {
      FixedText<agent_names_bytes> text;
      ds::Array<char, agent_names_bytes> bytes{};
      std::size_t size = 0;

      for (const auto agent : agent_names) {
        if (agents.contains(agent)) {
          const auto room = bytes.size() - size;
          const auto written = std::format_to_n(bytes.viewMut().subspan(size).data(), static_cast<std::ptrdiff_t>(room), "{}{}", size == 0 ? "" : ", ", agent);

          size += std::min(static_cast<std::size_t>(written.size), room);
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
        return {
            .tools = curl_bash.view(),
            .script = R"(if [ -f /etc/alpine-release ]; then
    if [ ! -e /usr/lib/libstdc++.so.6 ] || ! command -v rg >/dev/null 2>&1; then
        echo 'Claude Code on Alpine needs `apk add libgcc libstdc++ ripgrep` (as root) first' >&2
        exit 1
    fi
fi
fetch https://claude.ai/install.sh
bash "$installer" </dev/null
)",
        };
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

    constexpr std::size_t reason_bytes = 127;

    using Reason = ErrorText<reason_bytes>;

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

    // How a step that ran ended: failed, or changed the machine, or found it as it should be.
    Status stepStatus(bool failed, bool changed) noexcept {
      if (failed) {
        return Status::failed;
      }

      return changed ? Status::changed : Status::ok;
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

      report.end(Step::agents, stepStatus(failed, ran), "{} wanted: {}", wanted.size(), names(wanted).view());
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

          appendAssign(script, {.name = "telar", .value = platform.target});
          appendAssign(script, {.name = "agent", .value = agent});
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

      report.end(Step::integrations, stepStatus(failed, changed), "{}", names(present).view());
    }

    // The Neovim telar provisions for its editor panes, installed there by the telar that was
    // just set up: it fetches the release its own build names and keeps it only when its bytes
    // are the ones it expects. A host that cannot have it keeps its own Neovim: the note says why.
    // The Neovim this telar's own package brought, as the directory its version names beside
    // the directory of telar's programs; none when it brought none.
    ds::Option<std::filesystem::path> packagedEditor() {
      std::error_code failure;
      const auto versions = std::filesystem::path{ExecutablePath{}.view()}.parent_path().parent_path() / "share/telar/nvim";

      for (const auto& version : std::filesystem::directory_iterator{versions, failure}) {
        // A version is digits and dots: it is written into what the machine runs.
        const auto name = version.path().filename().native();
        const bool plain = !name.empty() && std::ranges::all_of(name, [](char letter) {
          return (letter >= '0' && letter <= '9') || letter == '.';
        });

        if (plain && ::access((version.path() / "bin/nvim").c_str(), X_OK) == 0) {
          return version.path();
        }
      }

      return ds::none;
    }

    // Sends the machine the Neovim of this telar's package, when the machine is of the system
    // and the processor the package is for: it then needs no network for it. False when there
    // is none to send, the machine is another kind, it has that Neovim already, or it could
    // not be sent: the machine's own telar then finds it or fetches it.
    bool sendEditor(Memory& memory, std::string_view destination, const Platform& platform) {
      const auto packaged = packagedEditor();
      if (!packaged) {
        return false;
      }

      // This system and this processor, named as the machine's are.
      const auto here = launch::capture(memory, launch::words(memory, {"uname", "-sm"}).view(), {}, install_timeout);
      const auto named = trimText(whole(here), " \t\r\n");
      const auto space = named.find(' ');
      if (here.status != 0 || space == std::string_view::npos) {
        return false;
      }

      try {
        // The releases of Neovim for Linux are glibc's.
        if (Platform::systemName(named.substr(0, space)) != platform.os || Platform::architectureName(named.substr(space + 1)) != platform.arch || (platform.os == "linux" && platform.libc != "gnu")) {
          return false;
        }
      } catch (const CommandError&) {
        return false;
      }

      const Text parent{memory, packaged->parent_path().native()};
      const Text version{memory, packaged->filename().native()};
      const auto packed = launch::capture(
          memory,
          launch::words(memory, {"/bin/sh", "-c", R"(archive=$(mktemp "${TMPDIR:-/tmp}/telar-nvim.XXXXXX") && tar -czf "$archive" -C "$1" "$2" && printf %s "$archive")", "sh", parent.view(), version.view()}).view(),
          {},
          install_timeout
      );
      if (packed.status != 0) {
        return false;
      }

      const Text archive_path{memory, trimText(whole(packed), " \t\r\n")};
      const FileDescriptor archive{::open(archive_path.data(), combineFlags(O_RDONLY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic

      static_cast<void>(::unlink(archive_path.data()));
      if (!archive) {
        return false;
      }

      // Unpacked beside its place and then moved there, so a run cut short leaves no half of it.
      const auto command = ds::format(
          memory,
          R"(exec /bin/sh -c 'set -eu; nvim=${{XDG_DATA_HOME:-$HOME/.local/share}}/telar/nvim; target=$nvim/{0}; if [ -x "$target/bin/nvim" ]; then cat >/dev/null; exit 0; fi; echo sent; mkdir -p "$nvim"; rm -rf "$target.incoming"; mkdir "$target.incoming"; tar -xzf - -C "$target.incoming"; rm -rf "$target"; mv "$target.incoming/{0}" "$target"; rmdir "$target.incoming"')",
          version.view()
      );

      const auto sent = launch::captureFile(memory, ssh(memory, destination, command).view(), archive.get(), install_timeout);

      return sent.status == 0 && whole(sent).contains("sent");
    }

    void provisionEditor(Memory& memory, SetupReport& report, std::string_view destination, const Platform& platform) {
      try {
        // The package's own Neovim goes first, where it fits the machine; the machine's telar
        // then finds it there and fetches nothing.
        const bool sent = sendEditor(memory, destination, platform);
        Text script{memory};

        appendAssign(script, {.name = "telar", .value = platform.target});
        script.append("exec \"$telar\" integration install editor\n");

        const auto output = runScript(memory, destination, script, install_timeout);
        if (output.status != 0) {
          report.note(Step::integrations, "editor: not provisioned: {}", output.errorLine());
          return;
        }

        if (sent) {
          report.note(Step::integrations, "editor: provisioned from this telar's package");
        } else {
          report.note(Step::integrations, "editor: {}", whole(output).contains("already present") ? "already provisioned" : "provisioned");
        }

        // What the host lacks for telar's own configuration, as the installer found it.
        for (const auto part : std::views::split(whole(output), '\n')) {
          if (const std::string_view line{part}; line.starts_with("editor: needs ")) {
            report.note(Step::integrations, "{}", line);
          }
        }
      } catch (const std::exception& error) {
        report.note(Step::integrations, "editor: not provisioned: {}", error.what());
      }
    }

    constexpr unsigned config_json_depth = 256;

    struct SyncEntry {
      tbc::val_static<std::string_view> name;
      enum class Format : std::uint8_t {
        text,
        json,
        toml,
        tree,
      } format = Format::text;
      bool hooks = false;
    };

    std::span<const SyncEntry> entriesFor(std::string_view agent) {
      using enum SyncEntry::Format;
      static constexpr ds::Array<SyncEntry, 9> claude_entries{{{.name = "settings.json", .format = json, .hooks = true}, {.name = "CLAUDE.md"}, {.name = "keybindings.json", .format = json}, {.name = "rules", .format = tree}, {.name = "skills", .format = tree}, {.name = "commands", .format = tree}, {.name = "agents", .format = tree}, {.name = "output-styles", .format = tree}, {.name = "themes", .format = tree}}};
      static constexpr ds::Array<SyncEntry, 6> codex_entries{{{.name = "config.toml", .format = toml}, {.name = "hooks.json", .format = json, .hooks = true}, {.name = "AGENTS.md"}, {.name = "AGENTS.override.md"}, {.name = "rules", .format = tree}, {.name = "prompts", .format = tree}}};
      static constexpr ds::Array<SyncEntry, 9> pi_entries{{{.name = "settings.json", .format = json}, {.name = "keybindings.json", .format = json}, {.name = "AGENTS.md"}, {.name = "SYSTEM.md"}, {.name = "APPEND_SYSTEM.md"}, {.name = "skills", .format = tree}, {.name = "prompts", .format = tree}, {.name = "themes", .format = tree}, {.name = "extensions", .format = tree}}};
      static constexpr ds::Array<SyncEntry, 10> opencode_entries{{{.name = "opencode.json", .format = json}, {.name = "opencode.jsonc", .format = json}, {.name = "tui.json", .format = json}, {.name = "AGENTS.md"}, {.name = "agents", .format = tree}, {.name = "commands", .format = tree}, {.name = "modes", .format = tree}, {.name = "skills", .format = tree}, {.name = "themes", .format = tree}, {.name = "plugins", .format = tree}}};
      static constexpr ds::Array<SyncEntry, 4> cursor_entries{{{.name = "cli-config.json", .format = json}, {.name = "hooks.json", .format = json, .hooks = true}, {.name = "skills", .format = tree}, {.name = "agents", .format = tree}}};

      if (agent == "claude") {
        return claude_entries.view();
      }

      if (agent == "codex") {
        return codex_entries.view();
      }

      if (agent == "pi") {
        return pi_entries.view();
      }

      if (agent == "opencode") {
        return opencode_entries.view();
      }

      return cursor_entries.view();
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

    // The variable that moves an agent's configuration directory away from the home.
    const char* rootVariable(std::string_view agent) noexcept {
      if (agent == "claude") {
        return "CLAUDE_CONFIG_DIR";
      }

      if (agent == "codex") {
        return "CODEX_HOME";
      }

      if (agent == "pi") {
        return "PI_CODING_AGENT_DIR";
      }

      return agent == "opencode" ? "XDG_CONFIG_HOME" : "CURSOR_CONFIG_DIR";
    }

    tbc::val_a<Text> localRoot(tbc::mut_a<Memory> memory, std::string_view agent, std::string_view home) {
      const auto* variable = rootVariable(agent);
      const auto* set = std::getenv(variable); // NOLINT(concurrency-mt-unsafe): POSIX has no thread-safe read of the environment
      const Text override{memory, set == nullptr ? std::string_view{} : std::string_view{set}};

      return !override.empty() ? ds::format(memory, "{}{}", override.view(), agent == "opencode" ? "/opencode" : "") : ds::format(memory, "{}/{}", home, remoteRoot(agent));
    }

    // Calls `visit` with each word of a shell command, split at its separators.
    template <typename Visit>
    void commandTokens(std::string_view command, const Visit& visit) {
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
      for (const auto* const prefix : {"~/", "$HOME/", "${HOME}/"}) {
        if (token.starts_with(prefix)) {
          return ds::format(memory, "{}/{}", home, token.substr(std::string_view{prefix}.size()));
        }
      }

      if (token.starts_with(home) && token.substr(home.size()).starts_with('/')) {
        return Text{memory, token};
      }

      return ds::none;
    }

    void commands(Memory& memory, JsonValue value, ds::Vec<Text, Memory>& output, bool inside = false) { // NOLINT(misc-no-recursion): a nested value recurses at most as deep as its JsonValue's maximum depth allows
      if (value.encoded().starts_with('{')) {
        value.eachMember([&](JsonValue key, JsonValue child) { // NOLINT(misc-no-recursion): a nested value recurses at most as deep as its JsonValue's maximum depth allows
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
        value.eachElement([&](JsonValue child) { // NOLINT(misc-no-recursion): a nested value recurses at most as deep as its JsonValue's maximum depth allows
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
        const auto* const position = std::ranges::lower_bound(texts_, text, {}, &Text::view);
        if (position != texts_.end() && *position == text) {
          return;
        }

        static_cast<void>(texts_.insert(static_cast<std::size_t>(position - texts_.begin()), Text{texts_.memory(), text}));
      }

      [[nodiscard]] bool contains(std::string_view text) const {
        return std::ranges::binary_search(texts_, text, {}, &Text::view);
      }

    private:
      tbc::val_a<ds::Vec<Text, Memory>> texts_;
    };

    // The modes a synced file takes there, by whether any execute bit is set here.
    constexpr mode_t regular_file_mode = 0644;
    constexpr mode_t executable_file_mode = 0755;
    constexpr mode_t executable_bits = 0111;

    constexpr std::size_t read_chunk_bytes = 16 * std::size_t{1024};

    // The agent whose hooks a settings file holds, by its static name.
    AgentProvider hookProvider(std::string_view agent) noexcept {
      if (agent == "claude") {
        return AgentProvider::claude;
      }

      return agent == "codex" ? AgentProvider::codex : AgentProvider::cursor;
    }

    class ConfigSync {
      struct File { // NOLINT(bugprone-exception-escape): its implicit move assignment, which removing a file uses, moves Texts, which allocate only between two allocators, and every text of the sync comes from the one memory
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
      [[nodiscard]] tbc::val_a<ds::Option<Text>> canonical(std::string_view path) const {
        const Text given{memory_, path};
        ds::Array<char, PATH_MAX> resolved{};
        if (::realpath(given.data(), resolved.dataMut()) == nullptr) {
          return ds::none;
        }

        return Text{memory_, std::string_view{resolved.data()}};
      }

      // A file or directory as the path it has there, from the home, and the canonical path it has here.
      struct Location {
        std::string_view remote;
        std::string_view real;
      };

      [[nodiscard]] bool inside(Location location) const {
        for (const auto& root : roots_) {
          if (below(location.remote, root.remote)) {
            return location.real == root.real.view() || below(location.real, root.real);
          }
        }

        return false;
      }

      [[nodiscard]] bool staged(std::string_view path) const {
        return std::ranges::any_of(files_, [&](const File& file) {
          return file.remote == path;
        });
      }

      // An agent's directory as the path it has there, from the home, and the path it has here.
      struct RootSource {
        std::string_view remote;
        std::string_view local;
      };

      bool addRoot(RootSource source) {
        auto real = canonical(source.local);
        if (!real) {
          return false;
        }

        roots_.push(Root{.remote = Text{memory_, source.remote}, .real = std::move(real.getMut())});
        return true;
      }

      // What telar installs in an agent's directory itself, which setup leaves to the other
      // machine's telar. `remote` names a file from the home; each path is from an agent's root,
      // or from the parent of a shared root such as .agents/skills.
      [[nodiscard]] bool owned(std::string_view remote) const {
        static constexpr auto paths = ds::Array<std::string_view, 4>{"skills/telar", "skills/telar-coordinator", "extensions/telar.ts", "plugins/telar.ts"};
        const auto matches = [](std::string_view relative) {
          return std::ranges::any_of(paths, [&](auto known) {
            return relative == known || below(relative, known);
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

        if (!inside({.remote = remote, .real = *real})) {
          leave("{}: leads outside its agent's directory, not sent", remote);
          return;
        }

        FileDescriptor file{::open(real->data(), combineFlags(O_RDONLY, O_NOFOLLOW, O_NONBLOCK, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
        struct stat state{};
        if (!file || ::fstat(file.get(), &state) != 0 || !S_ISREG(state.st_mode)) {
          return;
        }

        if (state.st_nlink > 1) {
          leave("{}: has another hard link, which could be any file; not sent", remote);
          return;
        }

        if (state.st_size < 0 || std::cmp_greater(state.st_size, config_receive::max_file_bytes)) {
          leave("{}: larger than 1024 KiB, not sent", remote);
          return;
        }

        if (files_.size() == config_receive::max_files || total_ + static_cast<std::uint64_t>(state.st_size) > config_receive::max_total_bytes) {
          leave("{}: the sync is full, not sent", remote);
          return;
        }

        Text bytes{memory_};
        ds::Array<char, read_chunk_bytes> buffer{};

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
        files_.push(File{.remote = Text{memory_, remote}, .bytes = std::move(bytes), .format = entry.format, .hooks = entry.hooks ? ds::Option{entry.name} : ds::none, .mode = (state.st_mode & executable_bits) != 0 ? executable_file_mode : regular_file_mode, .json = ds::none});
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

        // Room for a leaf name below the prefix that stands for an agent's directory.
        constexpr std::size_t prefix_bytes = 16;
        ds::Array<char, NAME_MAX + prefix_bytes> leaf{};
        const auto written = std::format_to_n(leaf.dataMut(), leaf.size(), ".claude/{}", path.substr(path.rfind('/') + 1));

        return static_cast<std::size_t>(written.size) <= leaf.size() && config_receive::acceptable({leaf.data(), static_cast<std::size_t>(written.size)});
      }

      void addTree(std::string_view local, std::string_view remote, unsigned depth) { // NOLINT(misc-no-recursion): each directory recurses one level deeper, at most max_depth levels
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

        if (!inside({.remote = remote, .real = *real})) {
          leave("{}/: leads outside its agent's directory, not sent", remote);
          return;
        }

        const Text local_text{memory_, local};
        FileDescriptor directory{::open(local_text.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
        if (!directory) {
          return;
        }

        DirectoryStream entries{directory.get()};

        while (const auto* entry = entries.next()) {
          const std::string_view name{std::data(entry->d_name)};
          if (name.empty() || name.front() == '.') {
            continue;
          }

          const auto target = ds::format(memory_, "{}/{}", remote, name);
          if (owned(target)) {
            continue;
          }

          // As the directory listing's types do, through symlinks.
          struct stat state{};
          if (::fstatat(directory.get(), name.data(), &state, 0) != 0) {
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

      // Stages the file a word of a command names below the home here, under each agent's root that holds it.
      void bringToken(std::string_view token) {
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
      }

      void bringCommands(const JsonValue& value) {
        ds::Vec<Text, Memory> found{memory_};

        commands(memory_, value, found);
        for (const auto& command : found) {
          commandTokens(command, [&](std::string_view token) {
            bringToken(token);
          });
        }
      }

      // Filters the JSON file at `index`, read from `original`: true when it stays, parsed, with telar's
      // hooks installed where it holds an agent's.
      bool filterJson(std::size_t index, const Text& original, std::string_view path, filter::Notes& dropped, std::string_view program) {
        const auto hooks = files_[index].hooks;

        try {
          const auto plain = filter::stripJsonc(memory_, original);

          // Validate duplicates and UTF-8 before traversing JsonValue.
          static_cast<void>(JsonNode<Memory>::parse(memory_, plain));
          Text filtered{memory_};

          filter::json(memory_, JsonValue::parse(plain, config_json_depth), filtered, dropped);
          bringCommands(JsonValue::parse(filtered, config_json_depth));
          auto node = JsonNode<Memory>::parse(memory_, filtered);
          const auto formatted = node.format();
          // Rewriting encoded strings keeps JSON escapes intact, including
          // a remote home containing quotes or backslashes.
          const auto rewritten = rewriteJson(JsonValue::parse(formatted, config_json_depth));

          node = JsonNode<Memory>::parse(memory_, rewritten);
          if (hooks) {
            if (node.kind() != JsonKind::object) {
              throw CommandError{"InvalidSettings"};
            }

            const integration::HookSettings settings{memory_, integration::Provider::describe(hookProvider(*hooks)), program};

            settings.install(node);
          }

          files_.atMut(index).json = std::move(node);
          return true;
        } catch (const CommandError& error) {
          if (std::string_view{error.what()} != "UnterminatedComment") {
            throw;
          }

          leave("{}: not valid JSON here, not sent", path);
          return false;
        } catch (const std::bad_alloc&) {
          throw;
        } catch (const std::exception&) {
          leave("{}: not valid JSON here, not sent", path);
          return false;
        }
      }

      void noteDropped(std::string_view path, const filter::Notes& dropped) {
        if (dropped.empty()) {
          return;
        }

        auto note = ds::format(memory_, "{}: left out ", path);

        for (const auto& name : dropped) {
          ds::formatTo(note, "{}{}", &name == dropped.data() ? "" : ", ", name);
        }

        left_.push(std::move(note));
      }

      void transform(std::string_view program) {
        for (std::size_t index = 0; index < files_.size();) {
          // Copied: bringing commands adds files, which can move these.
          const auto original = files_[index].bytes.clone();
          const auto path = files_[index].remote.clone();
          filter::Notes dropped{memory_};
          bool retain = true;

          if (files_[index].format == SyncEntry::Format::json) {
            retain = filterJson(index, original, path, dropped, program);
          } else {
            const auto filtered = files_[index].format == SyncEntry::Format::toml ? filter::toml(memory_, original, dropped) : original.clone();

            retain = keep(index, filter::rewriteHome(memory_, filtered, home_, remote_home_));
          }

          noteDropped(path, dropped);
          if (retain) {
            ++index;
          } else {
            static_cast<void>(files_.remove(index));
          }
        }
      }

      Text rewriteJson(JsonValue value) { // NOLINT(misc-no-recursion): a nested value recurses at most as deep as its JsonValue's maximum depth allows
        Text output{memory_};
        const auto encoded = value.encoded();
        if (encoded.starts_with('"')) {
          Text text{memory_};

          value.string(text);
          appendJsonText(output, filter::rewriteHome(memory_, text, home_, remote_home_).view(), JsonEscapes::standard);
        } else if (encoded.starts_with('{')) {
          output.push('{');
          bool first = true;

          value.eachMember([&](JsonValue key, JsonValue child) { // NOLINT(misc-no-recursion): a nested value recurses at most as deep as its JsonValue's maximum depth allows
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

          value.eachElement([&](JsonValue child) { // NOLINT(misc-no-recursion): a nested value recurses at most as deep as its JsonValue's maximum depth allows
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

      // A command a file runs there, and the home its `~` and `$HOME` words name there.
      struct RemoteCommand {
        std::string_view home;
        std::string_view command;
      };

      // The absolute paths a command names there: its absolute words and its words under the home.
      template <typename Visit>
      static void paths(Memory& memory, RemoteCommand remote, const Visit& visit) {
        commandTokens(remote.command, [&](std::string_view token) {
          if (token.starts_with('/')) {
            visit(token);
          } else if (const auto expanded = homePath(memory, token, remote.home)) {
            visit(expanded->view());
          }
        });
      }

      // The absolute paths the staged files' commands name there, in the order they name them.
      ds::Vec<Text, Memory> askedPaths() {
        ds::Vec<Text, Memory> asked{memory_};

        for (const auto& file : files_) {
          if (!file.json) {
            continue;
          }

          ds::Vec<Text, Memory> found{memory_};
          const auto formatted = file.json->format();

          commands(memory_, JsonValue::parse(formatted, config_json_depth), found);
          for (const auto& command : found) {
            askPaths(memory_, {.home = remote_home_, .command = command}, asked);
          }
        }

        return asked;
      }

      // Adds to `asked` the paths a command names there, each a line of the query's here-document.
      static void askPaths(Memory& memory, RemoteCommand remote, ds::Vec<Text, Memory>& asked) {
        paths(memory, remote, [&](std::string_view path) {
          if (!path.contains('\n') && path != "TELAR_PATHS") {
            asked.emplace(memory, path);
          }
        });
      }

      // The paths of `asked` that exist on the machine.
      SortedTexts existingPaths(std::string_view destination, const ds::Vec<Text, Memory>& asked) {
        SortedTexts result{memory_};
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

      SortedTexts queryPaths(std::string_view destination) {
        const auto asked = askedPaths();
        if (asked.empty()) {
          return SortedTexts{memory_};
        }

        return existingPaths(destination, asked);
      }

      static bool commandRuns(Memory& memory, std::string_view remote_home, const SortedTexts& staged, std::string_view command, const SortedTexts& existing) {
        if (command.ends_with(" hook claude") || command.ends_with(" hook codex") || command.ends_with(" hook cursor")) {
          return true;
        }

        bool runs = true;

        paths(memory, {.home = remote_home, .command = command}, [&](std::string_view path) {
          if (existing.contains(path) || (below(path, remote_home) && staged.contains(path.substr(remote_home.size() + 1)))) {
            return;
          }

          runs = false;
        });

        return runs;
      }

      // What pruning a file's commands reads, and where it notes each command it leaves out.
      struct Pruning {
        std::string_view remote_home;
        ds::Vec<Text, Memory>& left;
        const SortedTexts& staged;
        const SortedTexts& existing;
      };

      // Leaves out the commands whose programs the machine lacks, noting each in `left`. Static, so a call
      // takes the sync's fields apart from the file whose commands it prunes.
      static bool keepCommands(Pruning& pruning, JsonNode<Memory>& node, std::string_view path) { // NOLINT(misc-no-recursion): a node nests at most as deep as JsonNode's maximum depth allows
        auto& memory = pruning.left.memory();

        if (node.kind() == JsonKind::object) {
          if (const auto* command = node.find("command"); (command != nullptr) && command->kind() == JsonKind::string && !commandRuns(memory, pruning.remote_home, pruning.staged, command->text(), pruning.existing)) {
            pruning.left.push(ds::format(memory, "{}: left out `{}`, whose program is not there", path, command->text()));
            return false;
          }
        }

        if (node.kind() == JsonKind::array || node.kind() == JsonKind::object) {
          const bool had_items = !node.children().empty();

          for (std::size_t index = 0; index < node.children().size();) {
            auto& child = node.childrenMut()[index];
            const bool container = child.kind() == JsonKind::object || child.kind() == JsonKind::array;
            const bool recurse = container && (node.kind() == JsonKind::array || !child.children().empty());
            if (recurse && !keepCommands(pruning, child, path)) {
              node.erase(index);
            } else {
              ++index;
            }
          }

          return node.kind() == JsonKind::array ? !had_items || !node.children().empty() : !node.children().empty();
        }

        return true;
      }

      // Stages the agent's configuration: the files and trees its entries name below its root.
      void stageAgent(tbc::val_static<std::string_view> agent) {
        auto root = localRoot(memory_, agent, home_);
        const auto remote = remoteRoot(agent);
        if (!addRoot({.remote = remote, .local = root})) {
          local_roots_.push({agent, std::move(root)});
          return;
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

      // Stages each wanted agent's configuration, and the skills the agents share.
      void stage(AgentSet wanted) {
        for (const auto agent : agent_names) {
          if (wanted.contains(agent)) {
            stageAgent(agent);
          }
        }

        std::ranges::sort(local_roots_.viewMut(), {}, &std::pair<std::string_view, Text>::first);
        if (wanted.contains("codex") || wanted.contains("opencode") || wanted.contains("cursor")) {
          constexpr std::string_view shared = ".agents/skills";
          const auto local = ds::format(memory_, "{}/{}", home_, shared);
          if (addRoot({.remote = shared, .local = local})) {
            addTree(local, shared, 0);
          }
        }
      }

      // Leaves out of the staged JSON files the commands whose programs the machine lacks.
      void pruneCommands(const SortedTexts& existing) {
        // The files already staged, named apart from the files the commands are pruned in.
        SortedTexts staged{memory_};

        for (const auto& file : files_) {
          staged.insert(file.remote);
        }

        Pruning pruning{.remote_home = remote_home_, .left = left_, .staged = staged, .existing = existing};

        for (auto& file : files_.viewMut()) {
          if (!file.json || file.json->kind() != JsonKind::object) {
            continue;
          }

          if (auto* status = file.json.getMut().findMut("statusLine"); (status != nullptr) && !keepCommands(pruning, *status, file.remote)) {
            file.json.getMut().remove("statusLine");
          }

          if (auto* hooks = file.json.getMut().findMut("hooks")) {
            keepCommands(pruning, *hooks, file.remote);
          }
        }
      }

      // The stream `machine receive-config` reads there: each file that stays, then its end.
      Text streamText() {
        Text stream{memory_, "telar-config 1\n"};

        for (std::size_t index = 0; index < files_.size();) {
          if (files_[index].json) {
            if (!keep(index, Text{memory_, files_[index].json->format()})) {
              static_cast<void>(files_.remove(index));
              continue;
            }
          }

          const auto& file = files_[index];

          ds::formatTo(stream, "file {} {} {}\n{}\n", file.mode == executable_file_mode ? "755" : "644", file.bytes.size(), file.remote, file.bytes);
          ++index;
        }

        stream.append("end\n");
        return stream;
      }

      // Reports what the machine made of the stream it received.
      void reportReceived(SetupReport& report, const launch::Output& output) {
        constexpr std::string_view written_prefix = "written ";
        constexpr std::string_view refused_prefix = "refused ";
        auto lines = whole(output);
        std::size_t written = 0;

        while (!lines.empty()) {
          const auto end = lines.find('\n');
          const auto line = lines.substr(0, end);
          if (line.starts_with(written_prefix)) {
            ++written;
            report.note(Step::configuration, "{}", line);
          } else if (line.starts_with(refused_prefix)) {
            report.note(Step::configuration, "left alone there: {}", line.substr(refused_prefix.size()));
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

    public:
      // The home here and the home there, which the sync rewrites one into the other.
      struct Homes {
        std::string_view local;
        std::string_view remote;
      };

      ConfigSync(tbc::mut_a<Memory> memory, Homes homes)
          : memory_(memory),
            home_(memory, homes.local),
            remote_home_(memory, homes.remote),
            roots_(memory),
            local_roots_(memory),
            files_(memory),
            left_(memory) {}

      void run(SetupReport& report, std::string_view destination, const Platform& platform, AgentSet wanted) {
        stage(wanted);
        transform(platform.target);
        pruneCommands(queryPaths(destination));
        const auto sent = streamText();
        constexpr auto send_timeout = std::chrono::seconds{600};
        const auto output = launch::capture(memory_, ssh(memory_, destination, ds::format(memory_, "{} machine receive-config", platform.target)).view(), sent, send_timeout);
        if (output.status != 0) {
          report.end(Step::configuration, Status::failed, "the machine refused the sync: {}", output.errorLine());
          return;
        }

        reportReceived(report, output);
      }
    };

    void syncConfig(Memory& memory, SetupReport& report, std::string_view destination, const Platform& platform, AgentSet wanted) {
      if (wanted.empty()) {
        report.end(Step::configuration, Status::skipped, "no agent here to take configuration from");
        return;
      }

      try {
        const auto* variable = std::getenv("HOME"); // NOLINT(concurrency-mt-unsafe): POSIX has no thread-safe read of the environment
        if (variable == nullptr) {
          throw CommandError{"HomeUnavailable"};
        }

        const Text home{memory, variable};
        ConfigSync sync{memory, {.local = home.view(), .remote = platform.home}};

        sync.run(report, destination, platform, wanted);
      } catch (const std::exception& error) {
        report.end(Step::configuration, Status::failed, "{}; nothing more was written there", error.what());
      }
    }

    // Room for the decimal digits of any 64-bit number.
    constexpr std::size_t decimal_bytes = 24;

    // The decimal digits of a number, as a command argument.
    FixedText<decimal_bytes> decimal(std::uint64_t value) {
      ds::Array<char, decimal_bytes> digits{};
      FixedText<decimal_bytes> text;

      text.assign({digits.data(), std::to_chars(digits.dataMut(), std::to_address(digits.viewMut().end()), value).ptr});
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

    struct LoginLink { // NOLINT(bugprone-exception-escape): its implicit move assignment moves Texts, which allocate only between two allocators, and both texts of a link come from the one memory
      Text url;
      ds::Option<Text> code;
    };

    tbc::val_a<ds::Option<LoginLink>> findLoginLink(tbc::mut_a<Memory> memory, std::string_view text, const LoginPlan& plan) {
      std::string_view url;

      constexpr unsigned char delete_byte = 0x7f;

      for (std::size_t start = 0;;) {
        const auto found = text.find("https://", start);
        if (found == std::string_view::npos) {
          return ds::none;
        }

        start = found + 1;
        auto end = found;

        while (end < text.size() && static_cast<unsigned char>(text[end]) > ' ' && static_cast<unsigned char>(text[end]) < delete_byte && !std::string_view{"\"'<>`"}.contains(text[end])) {
          ++end;
        }

        auto candidate = text.substr(found, end - found);

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

      // Each agent's outcome, by its place in agent_names.
      using Results = ds::Array<ds::Option<MachineLogin>, agent_names.size()>;

      // An agent there: its name, its program's path there, and the provider it logs in with.
      struct Agent {
        std::string_view name;
        std::string_view path;
        ds::Option<std::string_view> provider;
      };

      struct Request {
        Agent agent;
        LoginPlan plan;
      };

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
        return {.workspace = number(required(value, "workspace_id")), .tab = number(required(value, "tab_id")), .pane = number(required(value, "pane_id"))};
      }

      Text capture(std::span<const std::string_view> words, ds::Option<std::string_view> input = ds::none) {
        // The same encoded command, length limit included, as every dispatch.
        const auto command = remoteCommand(memory_, profile_, words);
        auto output = launch::capture(memory_, ssh(memory_, profile_.destination(), command).view(), input.valueOr(std::string_view{}), status_timeout);

        std::print(stderr, "{}", output.err.view());
        if (output.status != 0) {
          throw CommandError{"MachineCommandFailed"};
        }

        static_cast<void>(whole(output));
        return std::move(output.out);
      }

      Text capture(std::initializer_list<std::string_view> words, ds::Option<std::string_view> input = ds::none) {
        ds::Vec<std::string_view, Memory> list{memory_};

        list.reserve(words.size());
        for (const auto word : words) {
          list.push(word);
        }

        return capture(list.view(), input);
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

        std::print(stderr, "{}", output.err.view());
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

      // The login pane a record names for `agent`, while it is still the plan's open there.
      ds::Option<LoginPane> find(std::string_view agent, const LoginPlan& plan) {
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
          if (number(required(value, "workspace_id")) == noted.workspace && string(required(value, "name")) == plan.title) {
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
        const auto current = find(agent, plan);
        if (!current || *current != pane) {
          return;
        }

        closeTab(pane);
        forget(agent);
      }

      LoginPane open(const Agent& agent, const LoginPlan& plan) {
        constexpr std::size_t workspace_words = 10;
        ds::Vec<std::string_view, Memory> words{memory_};

        words.extend(ds::Array<std::string_view, workspace_words>{"workspace", "create", "--directory", platform_.home, "--name", plan.title, "--columns", "1024", "--json", "--"}.view());
        if (plan.environment) {
          words.push("/usr/bin/env");
          words.push(*plan.environment);
        }

        words.push(agent.path);
        words.extend(plan.arguments);
        const auto output = capture(words.view());
        LoginPane created;

        try {
          created = pane(JsonValue::parse(output));
        } catch (const std::exception&) {
          throw CommandError{"LoginPaneUnreadable"};
        }

        try {
          remember(agent.name, created);
        } catch (...) {
          try {
            closeTab(created);
          } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): closing the pane is best effort; the failure to remember it is what propagates
          }

          throw;
        }

        return created;
      }

      ds::Option<Text> provider(std::string_view agent) {
        if (agent != "pi" && agent != "opencode") {
          return ds::none;
        }

        const auto* home = std::getenv("HOME"); // NOLINT(concurrency-mt-unsafe): POSIX has no thread-safe read of the environment
        if (home == nullptr) {
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
            // A file that does not read or parse leaves the next one to name the provider.
            continue;
          }
        }

        return ds::none;
      }

      bool loggedIn(const Agent& agent) {
        std::string_view check;

        if (agent.name == "claude") {
          check = "\"$agent\" auth status >/dev/null 2>&1";
        } else if (agent.name == "codex") {
          check = "\"$agent\" login status >/dev/null 2>&1";
        } else if (agent.name == "cursor") {
          check = R"("$agent" status --format json 2>/dev/null | grep -Eq '"status": *"authenticated"|"isAuthenticated": *true')";
        } else if (agent.name == "pi") {
          check = R"([ -n "$provider" ] && "$agent" auth check --provider "$provider" --no-refresh >/dev/null 2>&1)";
        } else {
          check = R"([ -n "$provider" ] && "$agent" auth list 2>/dev/null | grep -qi -- "$provider")";
        }

        Text bytes{memory_};

        appendAssign(bytes, {.name = "agent", .value = agent.path});
        appendAssign(bytes, {.name = "provider", .value = agent.provider.valueOr(std::string_view{})});
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

      ds::Option<MachineLogin> ended(const Agent& agent, const ds::Option<Read>& read, LoginPane pane) {
        if (read && !read->exit_code) {
          return ds::none;
        }

        const auto logged_in = loggedIn(agent);
        if (logged_in && (!read || read->exit_code == 0)) {
          return MachineLogin::done;
        }

        if (read && read->exit_code) {
          report_.note(Step::logins, "{}: login command exited with {}; status is {}. Read its diagnostic with pane read {} --json on {}, then retry setup", agent.name, *read->exit_code, logged_in ? "logged in" : "not logged in", pane.pane, profile_.label());
        } else {
          report_.note(Step::logins, "{}: login pane disappeared before authentication completed; retry setup", agent.name);
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
          const ServerOptions server_options{};
          const RuntimePaths<Memory> paths{memory_, server_options, process_environment};
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

      // Shows where to log in: the link the pane prints, or the plan's instructions. The login's
      // outcome where it ended first or no link appeared, else none.
      ds::Option<MachineLogin> showLink(const Request& request, LoginPane pane) {
        const auto& plan = request.plan;
        if (!plan.link) {
          announce(plan, ds::none);
          report_.progress("{} on {}: {}", plan.title, profile_.label(), plan.instructions);
          return ds::none;
        }

        const auto deadline = std::chrono::steady_clock::now() + link_timeout;
        ds::Option<LoginLink> found;

        while (std::chrono::steady_clock::now() < deadline) {
          const auto value = read(pane);
          if (const auto result = ended(request.agent, value, pane)) {
            close(request.agent.name, pane, plan);
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
          report_.progress("{}: no login link appeared in its pane on {}; finish it there", request.agent.name, profile_.label());
          return MachineLogin::pending;
        }

        report_.progress("{} on {}: {}", plan.title, profile_.label(), found->url);
        if (found->code) {
          report_.progress("one-time code: {}", *found->code);
        }

        if (!announce(plan, found)) {
          report_.progress("no window here took the notification; open the link above");
        }

        return ds::none;
      }

      // Asks the person here for what the login pane there waits for, and types it there.
      void askPaste(const Request& request, LoginPane pane) {
        constexpr std::size_t answer_bytes = max_notification_message_bytes * 8;

        std::print(stdout, "Paste {} for {} (Enter to finish in the pane instead): ", *request.plan.paste, request.agent.name);
        static_cast<void>(std::fflush(stdout));
        ds::Array<char, answer_bytes> answer{};
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

      // Waits for the login to end there, or for its agent to report itself logged in.
      MachineLogin awaitLogin(const Request& request, LoginPane pane) {
        const auto& agent = request.agent;
        const auto deadline = std::chrono::steady_clock::now() + finish_timeout;
        auto status_at = std::chrono::steady_clock::now();

        while (std::chrono::steady_clock::now() < deadline) {
          if (const auto result = ended(agent, read(pane), pane)) {
            close(agent.name, pane, request.plan);
            return *result;
          }

          if (std::chrono::steady_clock::now() >= status_at) {
            if (loggedIn(agent)) {
              close(agent.name, pane, request.plan);
              return MachineLogin::done;
            }

            status_at = std::chrono::steady_clock::now() + status_interval;
          }

          std::this_thread::sleep_for(poll_interval);
        }

        report_.note(Step::logins, "{}: authentication did not complete before the login timeout; retry setup", agent.name);
        close(agent.name, pane, request.plan);
        return MachineLogin::failed;
      }

      MachineLogin loginOne(const Request& request) {
        const auto& agent = request.agent;
        const auto& plan = request.plan;
        const auto existing = find(agent.name, plan);
        const auto pane = existing ? *existing : open(agent, plan);

        try {
          if (existing) {
            report_.progress("{} on {}: the login setup started before is still open there", plan.title, profile_.label());
          } else if (plan.keys) {
            send(pane, *plan.keys);
          }

          if (const auto shown = showLink(request, pane)) {
            return *shown;
          }

          if (!interactive_) {
            if (const auto result = ended(agent, read(pane), pane)) {
              close(agent.name, pane, plan);
              return *result;
            }

            return MachineLogin::pending;
          }

          if (plan.paste) {
            askPaste(request, pane);
          }

          return awaitLogin(request, pane);
        } catch (...) {
          try {
            close(agent.name, pane, plan);
          } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): closing the pane is best effort; the failure that stopped the login is what propagates
          }

          throw;
        }
      }

      // An agent already logged in there: its login pane, if one is left open, closes.
      MachineLogin closeLeftover(const Agent& agent, const ds::Option<LoginPlan>& plan) {
        try {
          if (plan) {
            if (const auto pane = find(agent.name, *plan)) {
              close(agent.name, *pane, *plan);
            }
          }
        } catch (const std::exception& error) {
          report_.note(Step::logins, "{}: its login cleanup failed: {}", agent.name, error.what());
          return MachineLogin::failed;
        }

        report_.note(Step::logins, "{}: logged in", agent.name);
        return MachineLogin::done;
      }

      MachineLogin startLogin(const Agent& agent, const LoginPlan& plan) {
        MachineLogin result = MachineLogin::failed;

        try {
          result = loginOne({.agent = agent, .plan = plan});
        } catch (const std::exception& error) {
          report_.note(Step::logins, "{}: {}", agent.name, error.what());
          return MachineLogin::failed;
        }

        if (result != MachineLogin::failed) {
          report_.note(Step::logins, "{}: {}", agent.name, machine_login_names[static_cast<std::size_t>(result)]);
        }

        return result;
      }

      // Logs `name` in there where it is not yet: its outcome, or none where setup leaves the login
      // to the person.
      ds::Option<MachineLogin> loginAgent(std::string_view name, bool& started) {
        const auto selected = provider(name);
        const Agent agent{.name = name, .path = platform_.agents.find(name)->view(), .provider = selected ? ds::Option{selected->view()} : ds::none};
        bool logged_in = false;

        try {
          logged_in = loggedIn(agent);
        } catch (const std::exception& error) {
          report_.note(Step::logins, "{}: its login status could not be read there: {}", name, error.what());
          return MachineLogin::failed;
        }

        const auto plan = planFor(name, agent.provider);

        if (logged_in) {
          return closeLeftover(agent, plan);
        }

        if (!plan) {
          report_.note(Step::logins, "{}: log in there yourself; setup has no browser login for {}", name, agent.provider.valueOr("its provider"));
          return ds::none;
        }

        started = true;
        return startLogin(agent, *plan);
      }

      static void recordResults(MachineProfiles& profiles, std::string_view label, const Results& results) {
        for (std::size_t index = 0; index < results.size(); ++index) {
          if (results[index]) {
            const auto* const found = std::ranges::find(machine_agent_names, agent_names[index]);

            profiles.recordLogin(label, static_cast<MachineAgent>(found - machine_agent_names.begin()), *results[index]);
          }
        }
      }

      // Records each outcome in machines.json; a failure to is noted and leaves the logins it had.
      void record(const Results& results, std::string_view profiles_path) {
        try {
          update(memory_, profiles_path, [&](MachineProfiles& profiles) {
            recordResults(profiles, profile_.label(), results);
          });
        } catch (const std::exception& error) {
          const auto* text = describe(error.what());

          report_.note(Step::logins, "machines.json keeps the logins it had: {}", (text != nullptr) ? text : error.what());
        }
      }

      // The step's outcome over every agent's, and the summary that names it.
      struct Outcome {
        Status status;
        std::string_view summary;
      };

      static Outcome outcome(const Results& results, bool any, bool started) {
        const auto has = [&](MachineLogin login) {
          return std::ranges::any_of(results, [&](const auto& entry) {
            return entry == ds::Option{login};
          });
        };

        if (has(MachineLogin::failed)) {
          return {.status = Status::failed, .summary = "a login failed; see the notes"};
        }

        if (!any) {
          return {.status = Status::skipped, .summary = "no agent there to log in"};
        }

        if (has(MachineLogin::pending)) {
          return {.status = Status::pending, .summary = "a login waits for you; run setup again to see it done"};
        }

        if (started) {
          return {.status = Status::changed, .summary = "every started login finished"};
        }

        return {.status = Status::ok, .summary = "every agent there is logged in"};
      }

    public:
      Logins(Memory& memory, SetupReport& report, const MachineProfile& profile, const Platform& platform, bool interactive)
          : memory_(memory),
            report_(report),
            profile_(profile),
            platform_(platform),
            interactive_(interactive) {}

      void run(AgentSet wanted, std::string_view profiles_path) {
        Results results{};
        bool started = false;

        for (std::size_t index = 0; index < agent_names.size(); ++index) {
          const auto agent = agent_names[index];
          if (!wanted.contains(agent) || !platform_.agents.contains(agent)) {
            continue;
          }

          results.atMut(index) = loginAgent(agent, started);
        }

        const bool any = std::ranges::any_of(results, [](const auto& entry) {
          return entry.hasValue();
        });

        if (any) {
          record(results, profiles_path);
        }

        const auto [status, summary] = outcome(results, any, started);

        report_.end(Step::logins, status, "{}", summary);
      }
    };

    // A byte a label keeps as it is; resolve turns any other into a dash.
    bool labelByte(char byte) noexcept {
      return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '.' || byte == '_' || byte == '-';
    }

  }

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

    if (const auto sign = host.rfind('@'); sign != std::string_view::npos) {
      host.remove_prefix(sign + 1);
    }

    while (host.starts_with('[')) {
      host.remove_prefix(1);
    }

    host = host.substr(0, host.find_first_of(":]/"));
    Text label{memory, host.substr(0, MachineLimits::label_bytes)};

    for (auto& byte : label.viewMut()) {
      if (!labelByte(byte)) {
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

    const MachineOptions trial{.action = MachineOptions::Action::add, .label = label, .value = options.label};
    auto copy = profiles;

    change(copy, trial);
    return {.label = std::move(label), .destination = Text{memory, options.label}, .saved = ds::none};
  }

  namespace {

    // A SHA-256 digest as hexadecimal digits, two to a byte.
    constexpr std::size_t digest_hex_bytes = std::size_t{SHA256_DIGEST_LENGTH} * 2;

    // A file's SHA-256, as 64 lowercase hexadecimal digits.
    using Digest = FixedText<digest_hex_bytes>;

    Digest fileDigest(const char* path) {
      constexpr std::size_t chunk_bytes = 64 * std::size_t{1024};
      FileDescriptor file{::open(path, combineFlags(O_RDONLY, O_NONBLOCK, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
      struct stat state{};
      if (!file || ::fstat(file.get(), &state) != 0 || !S_ISREG(state.st_mode)) {
        throw CommandError{"SetupBinaryUnreadable"};
      }

      Sha256 digest;
      ds::Array<char, chunk_bytes> buffer{};

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

        digest.update({buffer.data(), static_cast<std::size_t>(count)});
      }

      const auto bytes = digest.finish();
      ds::Array<char, digest_hex_bytes> digits{};
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

        appendAssign(script, {.name = "dir", .value = directory});
        script.append(assets::probe);
        return runScript(memory, target.destination, script);
      };

      try {
        probe = run();
        const auto failure = sshFailure(probe);
        if (probe.status != 0 && !report.json && (::isatty(STDIN_FILENO) != 0) && (failure == MachineError::host_key_rejected || failure == MachineError::authentication_failed)) {
          std::println(stdout, "Batch-mode SSH to {} was refused. Connecting once with your terminal: OpenSSH asks, you answer; telar accepts nothing for you.", target.destination.data());
          static_cast<void>(std::fflush(stdout));
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
      const auto* configured = std::getenv("TELAR_RELEASES_URL"); // NOLINT(concurrency-mt-unsafe): POSIX has no thread-safe read of the environment

      return (configured != nullptr) && ((*configured) != 0) ? std::string_view{configured} : std::string_view{"https://github.com/adriangs1996/telar/releases"};
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

      constexpr std::size_t max_sums_bytes = 64 * std::size_t{1024};
      if (output.status != 0 || output.dropped != 0 || output.out.size() > max_sums_bytes) {
        throw CommandError{"ReleaseUnavailable"};
      }

      auto lines = output.out.view();

      while (!lines.empty()) {
        const auto end = std::min(lines.find('\n'), lines.size());
        const auto words = trimText(lines.substr(0, end), " \t\r");

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

        if (digest.size() != digest_hex_bytes || !std::ranges::all_of(digest, [](unsigned char byte) {
              return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F');
            })) {
          throw CommandError{"ReleaseDigestUnreadable"};
        }

        ds::Array<char, digest_hex_bytes> lowered{};
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

          appendAssign(check, {.name = "target", .value = remote});
          appendAssign(check, {.name = "expected", .value = digest.view()});
          ds::formatTo(check, "{}[ -f \"$target\" ] && [ \"$(hash \"$target\")\" = \"$expected\" ]\n", hasher);
          const auto inspect = runScript(memory, target.destination, check);
          if (inspect.status == 0) {
            continue;
          }

          if (inspect.status == launch::ssh_failure) {
            throw CommandError{"SshFailed"};
          }

          FileDescriptor runtime{::open(sibling.data(), combineFlags(O_RDONLY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
          if (!runtime) {
            throw fileError(sys::lastError());
          }

          Text script{memory};

          appendAssign(script, {.name = "target", .value = remote});
          appendAssign(script, {.name = "expected", .value = digest.view()});
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

    // Uploads the --binary there beside the installed versions, named by its digest; false when it
    // failed, as reported.
    bool uploadBinary(Memory& memory, SetupReport& report, const Target& target, const Install& build) {
      const auto short_digest = build.digest->view().substr(0, MachineId::hex_digits);
      const auto upload_command = ds::format(memory, R"(exec /bin/sh -c 'umask 077 && mkdir -p "$HOME/.local/share/telar/versions" && exec cat > "$HOME/.local/share/telar/versions/.upload-{}"')", short_digest);
      const Text binary_path{memory, *build.binary};
      FileDescriptor binary{::open(binary_path.data(), combineFlags(O_RDONLY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
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

      return true;
    }

    // A development build has no release to download.
    constexpr bool development_build = version == "0.0.0";

    // The digest of the release the machine installs; none where it has none to install, as reported.
    ds::Option<Digest> releaseFor(Memory& memory, SetupReport& report, const Target& target, const Platform& platform) {
      if (development_build) {
        report.end(Step::telar, Status::failed, "this is a development build ({}) with no release to download; pass --binary with a telar built for {} {}", version, platform.os, platform.arch);
        return ds::none;
      }

      if (!platform.has("curl")) {
        report.end(Step::telar, Status::failed, "{} has no curl, which the installer needs to download the release; install curl there, or pass --binary", target.label);
        return ds::none;
      }

      const auto asset = platform.assetName(memory);

      try {
        return releaseDigest(memory, asset);
      } catch (const std::exception& error) {
        report.end(Step::telar, Status::failed, "{}: cannot read the hash of {} from release {} at {}", error.what(), asset, version, releasesUrl());
        return ds::none;
      }
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
        if (!uploadBinary(memory, report, target, build)) {
          return false;
        }

        ds::formatTo(script, "upload=$HOME/.local/share/telar/versions/.upload-{}\n", build.digest->view().substr(0, MachineId::hex_digits));
        appendAssign(script, {.name = "digest", .value = build.digest->view()});
        appendAssign(script, {.name = "bin_dir", .value = platform.binDirectory()});
        script.append("(\nset -- --binary \"$upload\" --sha256 \"$digest\" --bin-dir \"$bin_dir\"\n");
      } else {
        const auto digest = releaseFor(memory, report, target, platform);
        if (!digest) {
          return false;
        }

        appendAssign(script, {.name = "upload", .value = ""});
        appendAssign(script, {.name = "digest", .value = digest->view()});
        appendAssign(script, {.name = "version", .value = version});
        appendAssign(script, {.name = "bin_dir", .value = platform.binDirectory()});
        if (const auto* url = std::getenv("TELAR_RELEASES_URL")) { // NOLINT(concurrency-mt-unsafe): POSIX has no thread-safe read of the environment
          // Copied out of the environment, as std::env::var does: a call into the project may change it.
          const Text releases_url{memory, url};

          appendAssign(script, {.name = "TELAR_RELEASES_URL", .value = releases_url});
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
      return textView(schema.view());
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
        std::print(stdout, "A telar runtime of another build runs on {}. Stopping it ends every pane and agent it runs. Stop it now? [y/N] ", target.label.data());
        static_cast<void>(std::fflush(stdout));
        agreed = answeredYes();
      }

      if (!agreed) {
        report.end(Step::runtime, Status::failed, "a runtime of another telar build runs there and keeps its panes; this build cannot attach until it stops. Run setup again from a terminal and agree to stop it");
        return false;
      }

      Text script{memory};

      appendAssign(script, {.name = "target", .value = program});
      appendAssign(script, {.name = "stopping", .value = "is stopping"});
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
        } catch (const MachineFailure&) { // NOLINT(bugprone-empty-catch): a runtime that does not answer yet is asked again after the wait
        }

        std::this_thread::sleep_for(restart_wait);
      }

      report.end(Step::runtime, Status::failed, "the old runtime stopped but this build's did not answer");
      return false;
    }

    // A setup's own parts, which its steps share.
    struct SetupRun {
      Memory& memory;
      SetupReport& report;
      const MachineOptions& options;
      const Target& target;
      // machines.json, where setup saves the machine.
      const Text& path;
    };

    // The digest of the --binary and of its companions, which name the directory it installs to.
    void digestBinary(Memory& memory, tbc::mut_a<Install> build, tbc::val_a<std::string_view> binary_path) {
      build.binary = binary_path;
      const Text binary{memory, binary_path};

      build.digest = fileDigest(binary.data());
      ds::formatTo(build.directory, "-{}", build.digest->view().substr(0, MachineId::hex_digits));
      for (const std::string_view tool : {"telar-runtime", "telar-config-check"}) {
        const auto companion = ds::format(memory, "{}/{}", parentOf(binary_path), tool);
        if (::access(companion.data(), R_OK) != 0) {
          throw CommandError{"SetupBinaryCompanionsMissing"};
        }

        ds::formatTo(build.directory, "-{}", fileDigest(companion.data()).view().substr(0, MachineId::hex_digits));
      }
    }

    void printSetupFailure(const MachineOptions& options, const std::exception& error) {
      if (std::string_view{error.what()} == "DuplicateMachineLabel") {
        std::println(stderr, "telar machine setup: the label for {} is taken by another machine; name it with --label", options.label);
        return;
      }

      const auto* detail = describe(error.what());

      std::println(stderr, "telar machine setup: {}", (detail != nullptr) ? detail : error.what());
    }

    // Asks before changing the machine, as --confirm wants: the status setup ends with where it does
    // not go on, else none.
    ds::Option<int> confirm(SetupRun& run, bool interactive) {
      const auto& target = run.target;

      if (!interactive) {
        return run.report.refuse(run.memory, {.label = target.label, .destination = target.destination}, "--confirm needs a terminal to ask on; nothing was changed");
      }

      std::print(stdout, "This installs telar {} on {} ({}), and the agents you have here with their official installers; it copies their configuration, never a credential, and opens their logins there. Set it up? [y/N] ", version, target.label.data(), target.destination.data());
      static_cast<void>(std::fflush(stdout));
      if (!answeredYes()) {
        std::println(stdout, "Nothing was changed on {}.", target.label.data());
        return 0;
      }

      return ds::none;
    }

    // Links ~/.local/bin/telar there to the telar setup installed, where nothing else is there.
    void linkProgram(SetupRun& run, const Platform& platform) {
      Text link_script{run.memory};

      appendAssign(link_script, {.name = "telar", .value = platform.target});
      link_script.append(R"Link(link=$HOME/.local/bin/telar
if [ -L "$link" ] && [ "$(readlink "$link")" = "$telar" ]; then exit 0; fi
if [ -e "$link" ] && [ ! -L "$link" ]; then echo 'it is a file telar did not link, so it stays; remove it to let setup link it' >&2; exit 1; fi
mkdir -p "$HOME/.local/bin" && "$telar" cli install --dir "$HOME/.local/bin" >/dev/null && echo linked
)Link");
      const auto link = runScript(run.memory, run.target.destination, link_script);
      if (link.status != 0) {
        run.report.note(Step::runtime, "~/.local/bin/telar left as it was: {}", link.errorLine());
      } else if (link.out.view().contains("linked")) {
        run.report.note(Step::runtime, "~/.local/bin/telar now links to {}", platform.target);
      }
    }

    // Adds the machine to the saved ones where it is new, naming the telar setup installed there.
    void placeProfile(MachineProfiles& saved, const SetupRun& run, std::string_view program) {
      const auto& target = run.target;
      const auto& options = run.options;

      if (!target.saved) {
        const MachineOptions add{.action = MachineOptions::Action::add, .label = target.label, .value = target.destination, .disabled = options.disabled};

        change(saved, add);
      }

      saved.placeProgram(target.label, program);
      if (!options.disabled && target.saved) {
        saved.enable(target.label, true);
      }
    }

    // Saves the machine, enabled unless --disabled says otherwise, with the telar setup installed.
    void saveProfile(SetupRun& run, const Platform& platform) {
      const auto& target = run.target;
      const auto& options = run.options;

      try {
        const auto previous = target.saved ? target.saved->program() : ds::none;
        const bool changed = !target.saved || previous != ds::Option{platform.target.view()} || (!target.saved->enabled() && !options.disabled);
        if (changed) {
          update(run.memory, run.path, [&](MachineProfiles& saved) {
            placeProfile(saved, run, platform.target);
          });
        }

        const bool enabled = (target.saved && target.saved->enabled()) || !options.disabled;
        const std::string_view state = enabled ? "enabled" : "disabled, as asked";

        if (changed) {
          run.report.end(Step::profile, Status::changed, "{} {}, {}, telar at {}", target.label, target.saved ? "updated" : "saved", state, platform.target);
        } else {
          run.report.end(Step::profile, Status::ok, "{} is saved, {} and names {}", target.label, state, platform.target);
        }
      } catch (const std::exception& error) {
        const auto* description = describe(error.what());

        run.report.end(Step::profile, Status::failed, "{}", (description != nullptr) ? description : error.what());
      }
    }

    // The platform as the probe finds it again after the agents installed there; none where it does
    // not read, which leaves the one found before.
    tbc::val_a<ds::Option<Platform>> reprobe(tbc::mut_a<Memory> memory, const Target& target, const Install& build) {
      try {
        Text probe_script{memory};

        appendAssign(probe_script, {.name = "dir", .value = build.directory});
        probe_script.append(assets::probe);
        const auto probe = runScript(memory, target.destination, probe_script);
        if (probe.status == 0) {
          return Platform::parse(memory, whole(probe));
        }
      } catch (const std::exception&) {
        // The platform the first probe found stands.
        return ds::none;
      }

      return ds::none;
    }

    // The machine as machines.json saves it now, where it still names the same destination.
    ds::Option<MachineProfile> savedProfile(SetupRun& run) {
      try {
        const auto profiles = load(run.memory, run.path);
        if (const auto row = profiles.find(run.target.label); row && profiles.rows()[*row].destination() == run.target.destination.view()) {
          return profiles.rows()[*row];
        }
      } catch (const std::exception&) {
        // A machines.json that does not read records no login.
        return ds::none;
      }

      return ds::none;
    }

    void logIn(SetupRun& run, const Platform& platform, AgentSet wanted, bool interactive) {
      if (run.options.skip[2]) {
        run.report.end(Step::logins, Status::skipped, "--skip login");
        return;
      }

      const auto saved = savedProfile(run);
      if (!saved) {
        run.report.end(Step::logins, Status::skipped, "{} is not saved, so its logins cannot be recorded", run.target.label);
        return;
      }

      Logins logins{run.memory, run.report, *saved, platform, interactive};

      logins.run(wanted, run.path);
    }

    // Whether a window here can attach to the runtime there.
    void checkAttach(SetupRun& run, const MachineProfile& remote) {
      Text detail{run.memory};

      try {
        const auto found = discover(run.memory, remote, detail);

        if (found.compatible()) {
          run.report.end(Step::check, Status::ok, "a window can attach: schema {} on both sides", schemaText(handshake::schema_id));
        } else {
          run.report.end(Step::check, Status::failed, "schema {} there, {} here", schemaText(found.schema()), schemaText(handshake::schema_id));
        }
      } catch (const MachineFailure& error) {
        run.report.end(Step::check, Status::failed, "{}: {}", error.what(), trimText(detail, " \t\r\n"));
      }
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
          digestBinary(memory, build, *options.binary);
        }
      } catch (const std::exception& error) {
        printSetupFailure(options, error);
        return 1;
      }

      const auto& target = *resolved;
      SetupRun run{.memory = memory, .report = report, .options = options, .target = target, .path = path};

      if (!options.json) {
        std::println(stdout, "Setting up {} ({}) with telar {}", target.label.data(), target.destination.data(), version);
        static_cast<void>(std::fflush(stdout));
      }

      const bool interactive = !options.json && (::isatty(STDIN_FILENO) != 0);

      if (options.confirm) {
        if (const auto status = confirm(run, interactive)) {
          return *status;
        }
      }

      const auto platform = reach(memory, report, target, build.directory);
      if (!platform || !install(memory, report, target, *platform, build)) {
        return report.finish(memory, {.label = target.label, .destination = target.destination});
      }

      Random random;
      const auto remote = MachineProfile::create(MachineId::generate(random), {.label = target.label, .destination = target.destination, .program = platform->target.view()});

      if (!startRuntime(memory, report, target, remote, interactive)) {
        return report.finish(memory, {.label = target.label, .destination = target.destination});
      }

      linkProgram(run, *platform);
      saveProfile(run, *platform);
      const auto wanted = localAgents(memory);
      ds::Option<Platform> reprobed;

      if (options.skip[0]) {
        report.end(Step::agents, Status::skipped, "--skip agents");
      } else if (installAgents(memory, report, target.destination, *platform, wanted)) {
        reprobed = reprobe(memory, target, build);
      }

      const auto& current = reprobed ? *reprobed : *platform;

      integrateAgents(memory, report, target.destination, current);
      if (!options.skip[3]) {
        provisionEditor(memory, report, target.destination, current);
      }

      if (options.skip[1]) {
        report.end(Step::configuration, Status::skipped, "--skip config");
      } else {
        syncConfig(memory, report, target.destination, current, wanted);
      }

      logIn(run, current, wanted, interactive);
      checkAttach(run, remote);
      return report.finish(memory, {.label = target.label, .destination = target.destination});
    }

  }

}

namespace telar::runtime::cli {

  namespace {

    // `machine check`: the saved machine's reachability.
    int checkSaved(Memory& memory, const machines::MachineProfiles& profiles, const MachineOptions& options) {
      const auto row = profiles.find(options.label);
      if (!row) {
        throw machines::MachineFailure{machines::MachineError::unknown_machine};
      }

      return machine::check(memory, profiles.rows()[*row], options.json);
    }

    // `machine add --check` checks the machine before it is saved: the status of a check that
    // failed, else none.
    ds::Option<int> checkBeforeAdd(Memory& memory, const machines::MachineProfiles& profiles, const MachineOptions& options) {
      const auto profile = machine::newProfile(profiles, options);

      if (!options.check || options.setup) {
        return ds::none;
      }

      const auto status = machine::check(memory, profile, options.json);
      if (status != 0) {
        return status;
      }

      return ds::none;
    }

  }

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
      case MachineOptions::Action::check:
        return checkSaved(memory, profiles, options);
      case MachineOptions::Action::add:
        if (const auto status = checkBeforeAdd(memory, profiles, options)) {
          return *status;
        }

        break;
      case MachineOptions::Action::remove:
      case MachineOptions::Action::rename:
      case MachineOptions::Action::enable:
      case MachineOptions::Action::disable:
      case MachineOptions::Action::receive_config:
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
