#pragma once

#include "../integration/hook_settings.hpp"
#include "agents.hpp"
#include "config_filter.hpp"
#include <functional>

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

  static bool below(std::string_view path, std::string_view root) {
    return path.starts_with(root) && path.size() > root.size() && path[root.size()] == '/';
  }

  bool inside(std::string_view remote, std::string_view real) const {
    for (const auto &root : roots_) {
      if (below(remote, root.remote)) {
        return real == root.real || below(real, root.real);
      }
    }

    return false;
  }

  bool staged(std::string_view path) const {
    return std::ranges::any_of(files_, [&](const File &file) { return file.remote == path; });
  }

  bool addRoot(const std::string &remote, const std::string &local) {
    std::error_code error;
    const auto real = std::filesystem::canonical(local, error);
    if (error) {
      return false;
    }

    roots_.push_back({remote, real.string()});
    return true;
  }

  static bool owned(std::string_view remote) {
    static constexpr auto paths = std::to_array<std::string_view>({"skills/telar", "skills/telar-coordinator", "extensions/telar.ts", "plugins/telar.ts"});
    return std::ranges::any_of(paths, [&](auto path) { return remote == path || below(remote, path); });
  }

  void addFile(const std::string &local, const std::string &remote, SyncEntry entry) {
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

  static bool safeLocal(const std::string &path) {
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

  void addTree(const std::string &local, const std::string &remote, unsigned depth) {
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

  bool keep(std::size_t index, std::string bytes) {
    if (const auto found = filter::findSecret(bytes)) {
      left_.push_back(files_[index].remote + ": held back, line " + std::to_string(found->first) + " holds what looks like " + std::string{found->second} + "; review it and sync again");
      return false;
    }

    files_[index].bytes = std::move(bytes);
    return true;
  }

  void bringCommands(const JsonValue &value) {
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

  void transform(const std::string &program) {
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

  String<Memory> rewriteJson(JsonValue value) {
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

  std::vector<std::string> paths(std::string_view command) const {
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

  std::set<std::string> queryPaths(const std::string &destination) {
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

  bool commandRuns(std::string_view command, const std::set<std::string> &existing) const {
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

  bool keepCommands(JsonNode<Memory> &node, const std::set<std::string> &existing, const std::string &path) {
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
  ConfigSync(Memory &memory, std::string home, std::string remote_home)
      : memory_(memory),
        home_(std::move(home)),
        remote_home_(std::move(remote_home)) {}

  void run(SetupReport &report, const std::string &destination, const Platform &platform, const std::set<std::string> &wanted) {
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
