module;
#include <chrono>
#include <utility>
#include <cstddef>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>
#include <variant>
#include <bit>
#include <stdlib.h>

#include <string_view>
#include <array>
#include <concepts>
#include <cstdlib>

#include <stdexcept>
#include <cerrno>
#include <exception>
#include <fcntl.h>
#include <sys/stat.h>
#include <limits.h>
#include <unistd.h>
#include <cstdio>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#include <cstdint>
#include <span>
#include <algorithm>
#include <optional>

#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#include "integration_assets.hpp"
#include <cstring>

#include <limits>
#include <type_traits>
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#include <charconv>

#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif

export module telar.cli.integration.settings;

export import telar.config;
export import telar.platform;


export import telar.cli.server;


export import telar.cli.tab;


export import telar.base.text;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: integration/provider.cppm
export {
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

  inline static Provider describe(AgentProvider provider) {
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
  inline String<Memory> root(Memory &memory, const Environment &environment, bool legacy = false) const {
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
}

// Interface: integration/files.cppm
export {
namespace telar::runtime::cli::integration {

template <Allocator Memory>
String<Memory> joinPath(Memory &memory, std::string_view directory, std::string_view name) {
  String<Memory> path{directory, AllocatorRef<char, Memory>{memory}};
  path += '/';
  path += name;
  if (path.size() >= PATH_MAX || path.contains('\0')) {
    throw std::length_error{"Invalid integration file path"};
  }

  return path;
}

template <Allocator Memory>
std::optional<String<Memory>> read(Memory &memory, const String<Memory> &path, std::size_t maximum_bytes) {
  FileDescriptor file{::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOCTTY)};
  if (!file) {
    if (errno == ENOENT) {
      return std::nullopt;
    }

    throw SystemError{"Read integration file"};
  }

  struct stat state{};
  if (::fstat(file.get(), &state) == 0 && state.st_size >= 0 && static_cast<std::uint64_t>(state.st_size) >= maximum_bytes) {
    throw CommandError{"StreamTooLong"};
  }

  return readFileContents(memory, file.get(), maximum_bytes - 1);
}

template <Allocator Memory>
void createParents(const String<Memory> &path) {
  std::array<char, PATH_MAX> directory;
  if (path.size() >= directory.size() || path.contains('\0')) {
    throw std::length_error{"Invalid integration file path"};
  }

  std::copy(path.begin(), path.end(), directory.begin());
  directory[path.size()] = '\0';
  for (std::size_t index = 1; index < path.size(); ++index) {
    if (directory[index] == '/') {
      directory[index] = '\0';
      if (::mkdir(directory.data(), 0777) != 0 && errno != EEXIST) {
        throw SystemError{"Create integration directory"};
      }

      directory[index] = '/';
    }
  }
}

template <Allocator Memory>
void write(Memory &memory, const String<Memory> &path, std::string_view source, bool preserve_settings) {
  String<Memory> target{path, AllocatorRef<char, Memory>{memory}};
  std::optional<mode_t> permissions;
  if (preserve_settings) {
    std::array<char, PATH_MAX> resolved;
    if (::realpath(path.c_str(), resolved.data()) != nullptr) {
      target = resolved.data();
    }

    struct stat state{};
    if (::stat(target.c_str(), &state) == 0) {
      permissions = state.st_mode & 07777;
    }
  }

  resolveAbsolutePath(target);
  createParents(target);
  const auto separator = target.rfind('/');
  String<Memory> parent{target.data(), separator == 0 ? 1 : separator, AllocatorRef<char, Memory>{memory}};
  FileDescriptor directory{::open(parent.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
  if (!directory) {
    throw SystemError{"Open integration directory"};
  }

  const auto name = std::string_view{target}.substr(separator + 1);
  if (const int error = writePrivateFile(directory.get(), name, {reinterpret_cast<const unsigned char *>(source.data()), source.size()}, PrivateFileMode::replace)) {
    throw SystemError{"Publish integration file", error};
  }
  if (permissions && ::chmod(target.c_str(), *permissions) != 0) {
    throw SystemError{"Restore integration settings permissions"};
  }
}

}
}

// Interface: integration/skills.cppm
export {
namespace telar::runtime::cli::integration {

enum class Ownership { absent,
                       owned,
                       foreign };

inline std::string_view ownershipName(Ownership ownership) noexcept {
  switch (ownership) {
  case Ownership::absent:
    return "absent";
  case Ownership::owned:
    return "installed";
  case Ownership::foreign:
    return "foreign";
  }

  std::unreachable();
}

struct Skill {
  std::string_view name;
  std::string_view header;
  std::string_view marker;
  std::string_view text;
  bool legacy_header = false;
};

inline constexpr std::string_view telar_header = R"(---
name: telar
description: Drive telar, the terminal multiplexer and agent runtime this pane runs in. Use when the user asks about telar, about other panes, agents, workspaces or worktrees, about running or watching commands in terminals or on other machines, or when a command's output mentions telar. Teaches how to discover the installed telar's commands from its own help.
---
)";
inline constexpr std::string_view coordinator_header = R"(---
name: telar-coordinator
description: Delegate tasks to agents in their own Git worktrees and steer them through telar. Use when the user asks to implement, fix or build something in a separate worktree, or asks about, stops, redirects or reviews agents working in worktrees.
---
)";
inline constexpr auto skills = std::to_array<Skill>({
    {.name = "telar", .header = telar_header, .marker = "<!-- telar-integration: skill telar -->\n", .text = assets::telar_skill},
    {.name = "telar-coordinator", .header = coordinator_header, .marker = "<!-- telar-integration: skill telar-coordinator -->\n", .text = assets::coordinator_skill, .legacy_header = true},
});

template <Allocator Memory>
String<Memory> skillPath(Memory &memory, std::string_view root, const Skill &skill) {
  auto path = joinPath(memory, root, "skills");
  path = joinPath(memory, path, skill.name);
  return joinPath(memory, path, "SKILL.md");
}

template <Allocator Memory>
Ownership skillOwnership(const String<Memory> &path, const Skill &skill) noexcept {
  struct stat state{};
  if (::stat(path.c_str(), &state) != 0) {
    return errno == ENOENT ? Ownership::absent : Ownership::foreign;
  }

  std::array<char, 1024> buffer;
  const auto contents = readRegularFile(path, buffer);
  if (!contents) {
    return Ownership::foreign;
  }
  if (contents->contains(skill.marker) || (skill.legacy_header && contents->starts_with(skill.header) && contents->substr(skill.header.size()).starts_with('\n'))) {
    return Ownership::owned;
  }

  return Ownership::foreign;
}

template <Allocator Memory>
void installSkills(Memory &memory, std::string_view root) {
  for (const auto &skill : skills) {
    const auto path = skillPath(memory, root, skill);
    if (skillOwnership(path, skill) == Ownership::foreign) {
      std::printf("telar integration: skill %.*s at %s is not telar's; left untouched\n", static_cast<int>(skill.name.size()), skill.name.data(), path.c_str());
      continue;
    }

    String<Memory> contents{skill.header, AllocatorRef<char, Memory>{memory}};
    contents += skill.marker;
    contents += '\n';
    contents += skill.text;
    write(memory, path, contents, false);
    std::printf("telar integration: skill %.*s written to %s\n", static_cast<int>(skill.name.size()), skill.name.data(), path.c_str());
  }
}

template <Allocator Memory>
void reportSkills(Memory &memory, std::string_view root) {
  for (const auto &skill : skills) {
    const auto path = skillPath(memory, root, skill);
    std::printf("skill %.*s: %s at %s\n", static_cast<int>(skill.name.size()), skill.name.data(), ownershipName(skillOwnership(path, skill)).data(), path.c_str());
  }
}

template <Allocator Memory>
void removeSkills(Memory &memory, std::string_view root) noexcept {
  for (const auto &skill : skills) {
    try {
      const auto path = skillPath(memory, root, skill);
      if (skillOwnership(path, skill) == Ownership::owned) {
        ::unlink(path.c_str());
      }
    } catch (...) {
    }
  }
}

}
}

// Interface: integration/extension.cppm
export {
namespace telar::runtime::cli::integration {

struct Extension {
  std::string_view noun;
  std::string_view marker;
  std::string_view source;

  inline static Extension describe(AgentProvider provider) {
    if (provider == AgentProvider::pi) {
      return {"extension", "// telar-integration: pi", assets::pi_extension};
    }
    if (provider == AgentProvider::opencode) {
      return {"plugin", "// telar-integration: opencode", assets::opencode_extension};
    }

    throw std::invalid_argument{"Provider does not use an integration extension"};
  }

  template <Allocator Memory>
  inline String<Memory> render(Memory &memory, std::string_view executable) const {
    constexpr std::string_view placeholder = "\"__TELAR_EXECUTABLE__\"";
    const auto offset = source.find(placeholder);
    if (offset == std::string_view::npos) {
      throw std::invalid_argument{"Integration template lacks its executable placeholder"};
    }

    String<Memory> result{source.substr(0, offset), AllocatorRef<char, Memory>{memory}};
    appendJsonString(result, executable);
    result += source.substr(offset + placeholder.size());
    if (result.size() > maximum_bytes) {
      throw std::length_error{"Integration extension exceeds its bound"};
    }

    return result;
  }

  static constexpr std::size_t maximum_bytes = 64 * 1024;
};

template <Allocator Memory, EnvironmentLookup Environment>
int runExtension(Memory &memory, const IntegrationOptions &options, const Environment &environment, std::string_view executable) {
  const auto provider = Provider::describe(options.provider);
  const auto extension = Extension::describe(options.provider);
  const auto root = provider.root(memory, environment);
  const auto path = options.settings.empty() ? joinPath(memory, root, provider.file) : String<Memory>{options.settings, AllocatorRef<char, Memory>{memory}};
  const auto rendered = extension.render(memory, executable);
  const auto existing = read(memory, path, Extension::maximum_bytes);
  const bool owned = existing && existing->starts_with(extension.marker);
  if (options.action == IntegrationAction::status) {
    const auto ownership = !existing ? Ownership::absent : owned ? Ownership::owned
                                                                 : Ownership::foreign;
    std::printf("telar %s: %s at %s\n", extension.noun.data(), ownershipName(ownership).data(), path.c_str());
    reportSkills(memory, root);
    return 0;
  }

  if (existing && !owned && *existing != rendered) {
    const auto action = options.action == IntegrationAction::install ? "exists and is not telar's" : "is not telar's";
    const auto resolution = options.action == IntegrationAction::install ? "move it first" : "left untouched";
    std::fprintf(stderr, "telar integration: %s %s %s; %s\n", path.c_str(), action, extension.noun.data(), resolution);
    return 1;
  }

  if (options.action == IntegrationAction::install) {
    const char *state = "already present";
    if (!existing || *existing != rendered) {
      write(memory, path, rendered, false);
      state = existing ? "updated" : "installed";
    }

    std::printf("telar integration: %s %s %s at %s\n", provider.name.data(), extension.noun.data(), state, path.c_str());
    installSkills(memory, root);
    return 0;
  }

  if (existing) {
    if (::unlink(path.c_str()) != 0) {
      throw SystemError{"Remove integration extension"};
    }

    std::printf("telar integration: %s %s removed from %s\n", provider.name.data(), extension.noun.data(), path.c_str());
  } else {
    std::printf("telar integration: %s %s not present at %s\n", provider.name.data(), extension.noun.data(), path.c_str());
  }

  removeSkills(memory, root);
  return 0;
}

}
}

// Interface: integration/hook_settings.cppm
export {
namespace telar::runtime::cli::integration {

template <Allocator Memory>
class HookSettings {
public:
  inline explicit HookSettings(Memory &memory, Provider provider, std::string_view executable)
      : memory_(memory),
        provider_(provider),
        marker_{" hook ", AllocatorRef<char, Memory>{memory}},
        command_{AllocatorRef<char, Memory>{memory}},
        worktree_command_{AllocatorRef<char, Memory>{memory}} {
    if (executable.contains('\'')) {
      throw std::invalid_argument{"Unsupported integration executable path"};
    }

    marker_ += provider.name;
    worktree_command_ = "telar_hook_bin=${TELAR_BIN_PATH:-'";
    worktree_command_ += executable;
    worktree_command_ += "'}; exec \"$telar_hook_bin\"";
    worktree_command_ += marker_;
    command_ = "[ -n \"$TELAR_PANE_ID\" ] && [ -n \"$TELAR_PANE_GENERATION\" ] || exit 0; ";
    command_ += worktree_command_;
  }

  inline bool installed(const JsonNode<Memory> &settings, std::string_view event) const noexcept {
    const auto *hooks = settings.find("hooks");
    const auto *entries = hooks == nullptr ? nullptr : hooks->find(event);
    if (entries == nullptr || entries->kind() != JsonKind::array) {
      return false;
    }

    return std::ranges::any_of(entries->children(), [&](const auto &entry) { return findHook(entry) != nullptr; });
  }

  inline bool install(JsonNode<Memory> &settings) const {
    bool changed = false;
    if (provider_.flat_hooks && settings.find("version") == nullptr) {
      settings.setLiteral("version", "1");
      changed = true;
    }

    if (const auto *hooks = settings.find("hooks"); hooks && hooks->kind() != JsonKind::object) {
      throw CommandError{"SettingsFieldNotAnObject"};
    }

    auto &hooks = settings.ensure("hooks", JsonKind::object);
    changed = installEvents(hooks, provider_.events, command_, provider_.timeout) || changed;
    changed = installEvents(hooks, provider_.worktree_events, worktree_command_, worktree_timeout) || changed;
    return changed;
  }

  inline bool uninstall(JsonNode<Memory> &settings) const {
    auto *hooks = settings.find("hooks");
    if (hooks == nullptr || hooks->kind() != JsonKind::object) {
      return false;
    }

    const bool lifecycle_changed = removeEvents(*hooks, provider_.events);
    const bool worktrees_changed = removeEvents(*hooks, provider_.worktree_events);
    return lifecycle_changed || worktrees_changed;
  }

private:
  inline bool isOwnCommand(const JsonNode<Memory> &hook) const noexcept {
    const auto *command = hook.find("command");
    return command != nullptr && command->kind() == JsonKind::string && command->text().ends_with(marker_);
  }

  template <typename Node>
  inline Node *findHook(Node &entry) const noexcept {
    if (provider_.flat_hooks) {
      return isOwnCommand(entry) ? &entry : nullptr;
    }

    auto *hooks = entry.find("hooks");
    if (hooks == nullptr || hooks->kind() != JsonKind::array) {
      return nullptr;
    }
    for (auto &hook : hooks->children()) {
      if (isOwnCommand(hook)) {
        return &hook;
      }
    }

    return nullptr;
  }

  inline bool installEvents(JsonNode<Memory> &hooks, std::span<const std::string_view> events, std::string_view command, std::string_view timeout) const {
    bool changed = false;
    for (const auto event : events) {
      if (const auto *entries = hooks.find(event); entries && entries->kind() != JsonKind::array) {
        throw CommandError{"SettingsFieldNotAnArray"};
      }

      auto &entries = hooks.ensure(event, JsonKind::array);
      bool present = false;
      for (auto &entry : entries.children()) {
        auto *hook = findHook(entry);
        if (hook == nullptr) {
          continue;
        }

        present = true;
        if (hook->find("command")->text() != command) {
          hook->setString("command", command);
          changed = true;
        }
      }
      if (!present) {
        entries.append(newEntry(command, timeout));
        changed = true;
      }
    }

    return changed;
  }

  inline JsonNode<Memory> newEntry(std::string_view command, std::string_view timeout) const {
    JsonNode<Memory> hook{memory_};
    if (!provider_.flat_hooks) {
      hook.setString("type", "command");
    }

    hook.setString("command", command);
    hook.setLiteral("timeout", timeout);
    if (provider_.flat_hooks) {
      return hook;
    }

    JsonNode<Memory> entry{memory_};
    entry.ensure("hooks", JsonKind::array).append(std::move(hook));
    return entry;
  }

  inline bool removeEvents(JsonNode<Memory> &hooks, std::span<const std::string_view> events) const {
    bool changed = false;
    for (const auto event : events) {
      auto *entries = hooks.find(event);
      if (entries == nullptr || entries->kind() != JsonKind::array) {
        continue;
      }

      for (std::size_t index = 0; index < entries->children().size();) {
        auto &entry = entries->children()[index];
        bool empty = false;
        if (provider_.flat_hooks) {
          empty = isOwnCommand(entry);
          changed = empty || changed;
        } else if (auto *commands = entry.find("hooks"); commands != nullptr && commands->kind() == JsonKind::array) {
          for (std::size_t command = 0; command < commands->children().size();) {
            if (isOwnCommand(commands->children()[command])) {
              commands->erase(command);
              changed = true;
            } else {
              ++command;
            }
          }

          empty = commands->children().empty();
        }

        if (empty) {
          entries->erase(index);
        } else {
          ++index;
        }
      }
      if (entries->children().empty()) {
        hooks.remove(event);
      }
    }

    return changed;
  }

  Memory &memory_;
  static constexpr std::string_view worktree_timeout = "360";
  Provider provider_;
  String<Memory> marker_;
  String<Memory> command_;
  String<Memory> worktree_command_;
};

template <Allocator Memory>
HookSettings(Memory &memory, Provider provider, std::string_view executable) -> HookSettings<Memory>;

}
}

// Interface: integration/settings.cppm
export {
namespace telar::runtime::cli::integration {

inline constexpr std::size_t maximum_settings_bytes = 4 * 1024 * 1024;

template <Allocator Memory, EnvironmentLookup Environment>
std::optional<String<Memory>> legacySettings(Memory &memory, Provider provider, const Environment &environment) {
  if (provider.environment == nullptr || environment.lookup(provider.environment).empty() || environment.lookup("HOME").empty()) {
    return std::nullopt;
  }

  const auto current = joinPath(memory, provider.root(memory, environment), provider.file);
  auto legacy = joinPath(memory, provider.root(memory, environment, true), provider.file);
  std::array<char, PATH_MAX> legacy_path;
  std::array<char, PATH_MAX> current_path;
  if (::realpath(legacy.c_str(), legacy_path.data()) == nullptr) {
    return std::nullopt;
  }
  if (::realpath(current.c_str(), current_path.data()) != nullptr && std::string_view{legacy_path.data()} == current_path.data()) {
    return std::nullopt;
  }

  return legacy;
}

template <Allocator Memory>
bool reportLegacy(Memory &memory, const String<Memory> &path, const HookSettings<Memory> &hooks, Provider provider) {
  const auto source = read(memory, path, maximum_settings_bytes);
  if (!source) {
    return false;
  }

  std::optional<JsonNode<Memory>> settings;
  try {
    settings.emplace(JsonNode<Memory>::parse(memory, *source));
  } catch (const std::exception &) {
    return false;
  }
  for (const auto events : {provider.events, provider.worktree_events}) {
    for (const auto event : events) {
      if (hooks.installed(*settings, event)) {
        std::printf("telar integration: hooks remain in %s, which is not read while its directory variable is set; `telar integration uninstall %s --legacy` removes them\n", path.c_str(), provider.name.data());
        return true;
      }
    }
  }

  return false;
}

template <Allocator Memory, EnvironmentLookup Environment>
int runSettings(Memory &memory, const IntegrationOptions &options, const Environment &environment, std::string_view executable) {
  const auto provider = Provider::describe(options.provider);
  String<Memory> path{options.settings, AllocatorRef<char, Memory>{memory}};
  if (path.empty()) {
    if (options.legacy) {
      const auto legacy = legacySettings(memory, provider, environment);
      if (!legacy) {
        std::fprintf(stderr, "telar integration: no %s settings under the home directory differ from the ones in use\n", provider.name.data());
        return 1;
      }

      path = *legacy;
    } else {
      path = joinPath(memory, provider.root(memory, environment), provider.file);
    }
  }

  const HookSettings hooks{memory, provider, executable};
  const auto source = read(memory, path, maximum_settings_bytes);
  std::optional<JsonNode<Memory>> settings;
  try {
    settings.emplace(JsonNode<Memory>::parse(memory, source ? std::string_view{*source} : "{}"));
  } catch (const std::exception &) {
    std::fprintf(stderr, "telar integration: %s is not valid JSON\n", path.c_str());
    return 1;
  }
  if (settings->kind() != JsonKind::object) {
    std::fprintf(stderr, "telar integration: %s must contain a JSON object\n", path.c_str());
    return 1;
  }

  const auto separator = path.rfind('/');
  const auto root = separator == std::string_view::npos ? std::string_view{} : std::string_view{path}.substr(0, separator == 0 ? 1 : separator);
  if (root.empty()) {
    throw std::invalid_argument{"Invalid integration settings path"};
  }

  if (options.action == IntegrationAction::status) {
    for (const auto events : {provider.events, provider.worktree_events}) {
      for (const auto event : events) {
        std::printf("%.*s: %s\n", static_cast<int>(event.size()), event.data(), hooks.installed(*settings, event) ? "installed" : "absent");
      }
    }

    reportSkills(memory, root);
    if (options.settings.empty()) {
      if (const auto legacy = legacySettings(memory, provider, environment)) {
        reportLegacy(memory, *legacy, hooks, provider);
      }
    }

    return 0;
  }

  const bool installing = options.action == IntegrationAction::install;
  const bool changed = installing ? hooks.install(*settings) : hooks.uninstall(*settings);
  if (changed) {
    write(memory, path, settings->format(), true);
  }

  const char *state = installing ? changed ? "installed" : "already present" : changed ? "removed"
                                                                                       : "not present";
  std::printf("telar integration: %s hooks %s in %s\n", provider.name.data(), state, path.c_str());
  if (installing) {
    installSkills(memory, root);
    if (!provider.launch_note.empty()) {
      std::printf("telar integration: %.*s\n", static_cast<int>(provider.launch_note.size()), provider.launch_note.data());
    }
  } else if (changed || !options.legacy) {
    removeSkills(memory, root);
  }

  return 0;
}

}
}
