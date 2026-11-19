module telar.cli.integration.settings;
import telar.sys.posix;
import telar.tbc;
import telar.cli.base.command_error;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;
import telar.base.ds;

namespace telar::runtime::cli::integration::assets {

#include "integration_assets.inc"

}

namespace telar::runtime::cli::integration {

  ds::Option<std::string_view> skillText(std::string_view name) noexcept {
    if (name == "telar") {
      return assets::telar_skill;
    }

    if (name == "coordinator") {
      return assets::coordinator_skill;
    }

    return ds::none;
  }

  template <Allocator Memory>
  tbc::view<ds::String<Memory>, tbc::lt::a> joinPath(tbc::view<Memory&, tbc::lt::a> memory, std::string_view directory, std::string_view name) {
    ds::String<Memory> path{memory, directory};

    path.push('/');
    path.append(name);
    if (path.size() >= PATH_MAX || path.view().contains('\0')) {
      throw std::length_error{"Invalid integration file path"};
    }

    return path;
  }

  tbc::view<ds::Option<ds::String<Memory>>, tbc::lt::a> read(tbc::view<Memory&, tbc::lt::a> memory, const ds::String<Memory>& path, std::size_t maximum_bytes) {
    FileDescriptor file{::open(path.data(), O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOCTTY)};
    if (!file) {
      if (sys::lastError() == ENOENT) {
        return ds::none;
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
  void createParents(const ds::String<Memory>& path) {
    ds::Array<char, PATH_MAX> directory;
    if (path.size() >= directory.size() || path.view().contains('\0')) {
      throw std::length_error{"Invalid integration file path"};
    }

    std::ranges::copy(path.view(), directory.dataMut());
    directory.atMut(path.size()) = '\0';
    for (std::size_t index = 1; index < path.size(); ++index) {
      if (directory[index] == '/') {
        directory.atMut(index) = '\0';
        if (::mkdir(directory.data(), 0777) != 0 && sys::lastError() != EEXIST) {
          throw SystemError{"Create integration directory"};
        }

        directory.atMut(index) = '/';
      }
    }
  }

  template <Allocator Memory>
  void write(Memory& memory, const ds::String<Memory>& path, std::string_view source, bool preserve_settings) {
    ds::String<Memory> target{memory, path};
    ds::Option<mode_t> permissions;

    if (preserve_settings) {
      ds::Array<char, PATH_MAX> resolved;
      if (::realpath(path.data(), resolved.dataMut()) != nullptr) {
        target.assign(resolved.data());
      }

      struct stat state{};
      if (::stat(target.data(), &state) == 0) {
        permissions = state.st_mode & 07777;
      }
    }

    resolveAbsolutePath(target);
    createParents(target);
    const auto separator = target.view().rfind('/');
    ds::String<Memory> parent{memory, std::string_view{target.data(), separator == 0 ? 1 : separator}};
    FileDescriptor directory{::open(parent.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
    if (!directory) {
      throw SystemError{"Open integration directory"};
    }

    const auto name = std::string_view{target}.substr(separator + 1);
    if (const int error = writePrivateFile(directory.get(), name, {reinterpret_cast<const unsigned char*>(source.data()), source.size()}, PrivateFileMode::replace)) {
      throw SystemError{"Publish integration file", error};
    }

    if (permissions && ::chmod(target.data(), *permissions) != 0) {
      throw SystemError{"Restore integration settings permissions"};
    }
  }

  enum class Ownership {
    absent,
    owned,
    foreign,
  };

  std::string_view ownershipName(Ownership ownership) noexcept {
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

  constexpr std::string_view telar_header = R"(---
name: telar
description: Drive telar, the terminal multiplexer and agent runtime this pane runs in. Use when the user asks about telar, about other panes, agents, workspaces or worktrees, about running or watching commands in terminals or on other machines, or when a command's output mentions telar. Teaches how to discover the installed telar's commands from its own help.
---
)";
  constexpr std::string_view coordinator_header = R"(---
name: telar-coordinator
description: Delegate tasks to agents in their own Git worktrees and steer them through telar. Use when the user asks to implement, fix or build something in a separate worktree, or asks about, stops, redirects or reviews agents working in worktrees.
---
)";
  constexpr auto skills = ds::Array<Skill, 2>{{
      {.name = "telar", .header = telar_header, .marker = "<!-- telar-integration: skill telar -->\n", .text = assets::telar_skill},
      {.name = "telar-coordinator", .header = coordinator_header, .marker = "<!-- telar-integration: skill telar-coordinator -->\n", .text = assets::coordinator_skill, .legacy_header = true},
  }};

  template <Allocator Memory>
  tbc::view<ds::String<Memory>, tbc::lt::a> skillPath(tbc::view<Memory&, tbc::lt::a> memory, std::string_view root, const Skill& skill) {
    auto path = joinPath(memory, root, "skills");

    path = joinPath(memory, path, skill.name);
    return joinPath(memory, path, "SKILL.md");
  }

  template <Allocator Memory>
  Ownership skillOwnership(const ds::String<Memory>& path, const Skill& skill) noexcept {
    struct stat state{};
    if (::stat(path.data(), &state) != 0) {
      return sys::lastError() == ENOENT ? Ownership::absent : Ownership::foreign;
    }

    ds::Array<char, 1024> buffer;
    const auto contents = readRegularFile(path, buffer.viewMut());
    if (!contents) {
      return Ownership::foreign;
    }

    if (contents->contains(skill.marker) || (skill.legacy_header && contents->starts_with(skill.header) && contents->substr(skill.header.size()).starts_with('\n'))) {
      return Ownership::owned;
    }

    return Ownership::foreign;
  }

  template <Allocator Memory>
  void installSkills(Memory& memory, std::string_view root) {
    for (const auto& skill : skills) {
      const auto path = skillPath(memory, root, skill);
      if (skillOwnership(path, skill) == Ownership::foreign) {
        std::printf("telar integration: skill %.*s at %s is not telar's; left untouched\n", static_cast<int>(skill.name.size()), skill.name.data(), path.data());
        continue;
      }

      ds::String<Memory> contents{memory, skill.header};

      contents.append(skill.marker);
      contents.push('\n');
      contents.append(skill.text);
      write(memory, path, contents, false);
      std::printf("telar integration: skill %.*s written to %s\n", static_cast<int>(skill.name.size()), skill.name.data(), path.data());
    }
  }

  template <Allocator Memory>
  void reportSkills(Memory& memory, std::string_view root) {
    for (const auto& skill : skills) {
      const auto path = skillPath(memory, root, skill);

      std::printf("skill %.*s: %s at %s\n", static_cast<int>(skill.name.size()), skill.name.data(), ownershipName(skillOwnership(path, skill)).data(), path.data());
    }
  }

  template <Allocator Memory>
  void removeSkills(Memory& memory, std::string_view root) noexcept {
    for (const auto& skill : skills) {
      try {
        const auto path = skillPath(memory, root, skill);
        if (skillOwnership(path, skill) == Ownership::owned) {
          ::unlink(path.data());
        }
      } catch (...) {
      }
    }
  }

  struct Extension {
    std::string_view noun;
    std::string_view marker;
    std::string_view source;

    static Extension describe(AgentProvider provider) {
      if (provider == AgentProvider::pi) {
        return {"extension", "// telar-integration: pi", assets::pi_extension};
      }

      if (provider == AgentProvider::opencode) {
        return {"plugin", "// telar-integration: opencode", assets::opencode_extension};
      }

      throw std::invalid_argument{"Provider does not use an integration extension"};
    }

    // The text lives in the memory it is written to, region `a`.
    template <Allocator Memory>
    tbc::view<ds::String<Memory>, tbc::lt::a> render(tbc::view<Memory&, tbc::lt::a> memory, std::string_view executable) const {
      constexpr std::string_view placeholder = "\"__TELAR_EXECUTABLE__\"";
      const auto offset = source.find(placeholder);
      if (offset == std::string_view::npos) {
        throw std::invalid_argument{"Integration template lacks its executable placeholder"};
      }

      ds::String<Memory> result{memory, source.substr(0, offset)};

      appendJsonText(result, executable);
      result.append(source.substr(offset + placeholder.size()));
      if (result.size() > maximum_bytes) {
        throw std::length_error{"Integration extension exceeds its bound"};
      }

      return result;
    }

    static constexpr std::size_t maximum_bytes = 64 * 1024;
  };

  template <EnvironmentLookup Environment>
  int runExtension(Memory& memory, const IntegrationOptions& options, const Environment& environment, std::string_view executable) {
    const auto provider = Provider::describe(options.provider);
    const auto extension = Extension::describe(options.provider);
    const auto root = provider.root(memory, environment);
    const auto path = options.settings.empty() ? joinPath(memory, root, provider.file) : ds::String<Memory>{memory, options.settings};
    const auto rendered = extension.render(memory, executable);
    const auto existing = read(memory, path, Extension::maximum_bytes);
    const bool owned = existing && existing->view().starts_with(extension.marker);

    if (options.action == IntegrationAction::status) {
      const auto ownership = !existing ? Ownership::absent : owned ? Ownership::owned
                                                                   : Ownership::foreign;

      std::printf("telar %s: %s at %s\n", extension.noun.data(), ownershipName(ownership).data(), path.data());
      reportSkills(memory, root);
      return 0;
    }

    if (existing && !owned && *existing != rendered) {
      const auto action = options.action == IntegrationAction::install ? "exists and is not telar's" : "is not telar's";
      const auto resolution = options.action == IntegrationAction::install ? "move it first" : "left untouched";

      std::fprintf(stderr, "telar integration: %s %s %s; %s\n", path.data(), action, extension.noun.data(), resolution);
      return 1;
    }

    if (options.action == IntegrationAction::install) {
      const char* state = "already present";

      if (!existing || *existing != rendered) {
        write(memory, path, rendered, false);
        state = existing ? "updated" : "installed";
      }

      std::printf("telar integration: %s %s %s at %s\n", provider.name.data(), extension.noun.data(), state, path.data());
      installSkills(memory, root);
      return 0;
    }

    if (existing) {
      if (::unlink(path.data()) != 0) {
        throw SystemError{"Remove integration extension"};
      }

      std::printf("telar integration: %s %s removed from %s\n", provider.name.data(), extension.noun.data(), path.data());
    } else {
      std::printf("telar integration: %s %s not present at %s\n", provider.name.data(), extension.noun.data(), path.data());
    }

    removeSkills(memory, root);
    return 0;
  }

  constexpr std::size_t maximum_settings_bytes = 4 * 1024 * 1024;

  template <Allocator Memory, EnvironmentLookup Environment>
  tbc::view<ds::Option<ds::String<Memory>>, tbc::lt::a> legacySettings(tbc::view<Memory&, tbc::lt::a> memory, Provider provider, const Environment& environment) {
    if (provider.environment == nullptr || environment.lookup(provider.environment).empty() || environment.lookup("HOME").empty()) {
      return ds::none;
    }

    const auto current = joinPath(memory, provider.root(memory, environment), provider.file);
    auto legacy = joinPath(memory, provider.root(memory, environment, true), provider.file);
    ds::Array<char, PATH_MAX> legacy_path;
    ds::Array<char, PATH_MAX> current_path;

    if (::realpath(legacy.data(), legacy_path.dataMut()) == nullptr) {
      return ds::none;
    }

    if (::realpath(current.data(), current_path.dataMut()) != nullptr && std::string_view{legacy_path.data()} == current_path.data()) {
      return ds::none;
    }

    return legacy;
  }

  bool reportLegacy(Memory& memory, const ds::String<Memory>& path, const HookSettings& hooks, Provider provider) {
    const auto source = read(memory, path, maximum_settings_bytes);
    if (!source) {
      return false;
    }

    ds::Option<JsonNode<Memory>> settings;

    try {
      settings.emplace(JsonNode<Memory>::parse(memory, *source));
    } catch (const std::exception&) {
      return false;
    }

    for (const auto events : {provider.events, provider.worktree_events}) {
      for (const auto event : events) {
        if (hooks.installed(*settings, event)) {
          std::printf("telar integration: hooks remain in %s, which is not read while its directory variable is set; `telar integration uninstall %s --legacy` removes them\n", path.data(), provider.name.data());
          return true;
        }
      }
    }

    return false;
  }

  template <EnvironmentLookup Environment>
  int runSettings(Memory& memory, const IntegrationOptions& options, const Environment& environment, std::string_view executable) {
    const auto provider = Provider::describe(options.provider);
    ds::String<Memory> path{memory, options.settings};
    if (path.empty()) {
      if (options.legacy) {
        const auto legacy = legacySettings(memory, provider, environment);
        if (!legacy) {
          std::fprintf(stderr, "telar integration: no %s settings under the home directory differ from the ones in use\n", provider.name.data());
          return 1;
        }

        path.assign(*legacy);
      } else {
        path = joinPath(memory, provider.root(memory, environment), provider.file);
      }
    }

    const HookSettings hooks{memory, provider, executable};
    const auto source = read(memory, path, maximum_settings_bytes);
    ds::Option<JsonNode<Memory>> settings;

    try {
      settings.emplace(JsonNode<Memory>::parse(memory, source ? std::string_view{*source} : "{}"));
    } catch (const std::exception&) {
      std::fprintf(stderr, "telar integration: %s is not valid JSON\n", path.data());
      return 1;
    }

    if (settings->kind() != JsonKind::object) {
      std::fprintf(stderr, "telar integration: %s must contain a JSON object\n", path.data());
      return 1;
    }

    const auto separator = path.view().rfind('/');
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
    const bool changed = installing ? hooks.install(settings.getMut()) : hooks.uninstall(settings.getMut());
    if (changed) {
      write(memory, path, settings->format(), true);
    }

    const char* state = installing ? changed ? "installed" : "already present" : changed ? "removed"
                                                                                         : "not present";

    std::printf("telar integration: %s hooks %s in %s\n", provider.name.data(), state, path.data());
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

  // The first line of every file telar's Neovim plugin writes: only those are replaced or removed.
  constexpr std::string_view neovim_marker = "-- telar-integration: neovim\n";
  constexpr std::size_t maximum_neovim_file_bytes = 256 * 1024;

  // $XDG_DATA_HOME/$NVIM_APPNAME/site, as Neovim's stdpath("data") .. "/site" names it.
  template <EnvironmentLookup Environment>
  tbc::view<ds::String<Memory>, tbc::lt::a> neovimSite(tbc::view<Memory&, tbc::lt::a> memory, const Environment& environment) {
    const auto application = environment.lookup("NVIM_APPNAME");
    if (application.starts_with('/') || application.contains("..")) {
      throw std::invalid_argument{"InvalidNvimAppName"};
    }

    ds::String<Memory> data{memory, environment.lookup("XDG_DATA_HOME")};

    if (!data.view().starts_with('/')) {
      data.assign(environment.lookup("HOME"));
      if (data.empty()) {
        throw std::invalid_argument{"Home directory unavailable for integration"};
      }

      data.append("/.local/share");
    }

    return joinPath(memory, joinPath(memory, data, application.empty() ? "nvim" : application), "site");
  }

  // The telar-owned files under the package's directories that the package no longer has.
  template <Allocator Memory>
  void removeStaleNeovimFiles(Memory& memory, std::string_view site) noexcept {
    ds::Array<std::string_view, std::size(assets::neovim_files)> directories{};
    std::size_t count = 0;

    for (const auto& file : assets::neovim_files) {
      const auto directory = file.path.substr(0, file.path.rfind('/'));
      if (std::ranges::find(directories.view().first(count), directory) == directories.view().first(count).end()) {
        directories.atMut(count++) = directory;
      }
    }

    for (const auto directory : directories.view().first(count)) {
      try {
        const auto path = joinPath(memory, site, directory);
        std::unique_ptr<DIR, decltype(&::closedir)> listing{::opendir(path.data()), &::closedir};
        if (!listing) {
          continue;
        }

        while (const auto* entry = ::readdir(listing.get())) {
          const std::string_view name = entry->d_name;
          if (!name.ends_with(".lua")) {
            continue;
          }

          const auto packaged = std::ranges::any_of(assets::neovim_files, [&](const auto& file) {
            return file.path.starts_with(directory) && file.path.size() == directory.size() + 1 + name.size() && file.path.ends_with(name);
          });

          const auto stale = joinPath(memory, path, name);
          const auto existing = packaged ? ds::Option<ds::String<Memory>>{} : read(memory, stale, maximum_neovim_file_bytes);
          if (existing && existing->view().starts_with(neovim_marker)) {
            ::unlink(stale.data());
            std::printf("telar integration: neovim %s removed, no longer part of the plugin\n", stale.data());
          }
        }
      } catch (...) {
      }
    }
  }

  template <EnvironmentLookup Environment>
  int runNeovim(Memory& memory, const IntegrationOptions& options, const Environment& environment) {
    const auto site = options.settings.empty() ? neovimSite(memory, environment) : ds::String<Memory>{memory, options.settings};
    bool foreign = false;

    // A file another tool or the user wrote stops the whole install, before anything changes.
    for (const auto& file : assets::neovim_files) {
      const auto path = joinPath(memory, site, file.path);
      const auto existing = read(memory, path, maximum_neovim_file_bytes);
      const auto ownership = !existing ? Ownership::absent : existing->view().starts_with(neovim_marker) ? Ownership::owned
                                                                                                         : Ownership::foreign;

      if (options.action == IntegrationAction::status) {
        std::printf("neovim %.*s: %s at %s\n", static_cast<int>(file.path.size()), file.path.data(), ownershipName(ownership).data(), path.data());
      } else if (ownership == Ownership::foreign) {
        std::fprintf(stderr, "telar integration: %s is not telar's neovim plugin; %s\n", path.data(), options.action == IntegrationAction::install ? "move it first" : "left untouched");
        foreign = true;
      }
    }

    if (options.action == IntegrationAction::status || (foreign && options.action == IntegrationAction::install)) {
      return foreign ? 1 : 0;
    }

    for (const auto& file : assets::neovim_files) {
      const auto path = joinPath(memory, site, file.path);
      const auto existing = read(memory, path, maximum_neovim_file_bytes);
      if (existing && !existing->view().starts_with(neovim_marker)) {
        continue;
      }

      if (options.action == IntegrationAction::uninstall) {
        if (existing && ::unlink(path.data()) != 0) {
          throw SystemError{"Remove integration file"};
        }

        std::printf("telar integration: neovim %.*s %s %s\n", static_cast<int>(file.path.size()), file.path.data(), existing ? "removed from" : "not present at", path.data());
        continue;
      }

      ds::String<Memory> contents{memory, neovim_marker};
      const char* state = "already present";

      contents.append(file.text);
      if (!existing || *existing != contents) {
        write(memory, path, contents, false);
        state = existing ? "updated" : "installed";
      }

      std::printf("telar integration: neovim %.*s %s at %s\n", static_cast<int>(file.path.size()), file.path.data(), state, path.data());
    }

    removeStaleNeovimFiles(memory, site);
    return foreign ? 1 : 0;
  }

  template int runExtension<ProcessEnvironment>(Memory& memory, const IntegrationOptions& options, const ProcessEnvironment& environment, std::string_view executable);
  template int runNeovim<ProcessEnvironment>(Memory& memory, const IntegrationOptions& options, const ProcessEnvironment& environment);
  template int runSettings<ProcessEnvironment>(Memory& memory, const IntegrationOptions& options, const ProcessEnvironment& environment, std::string_view executable);

}

namespace telar::runtime::cli {

  IntegrationOptions IntegrationOptions::parse(std::span<char* const> arguments) {
    if (arguments.size() < 2) {
      throw std::invalid_argument{"MissingIntegrationArguments"};
    }

    IntegrationOptions options;
    const std::string_view action = arguments[0];
    if (action == "install") {
      options.action = IntegrationAction::install;
    } else if (action == "uninstall") {
      options.action = IntegrationAction::uninstall;
    } else if (action != "status") {
      throw std::invalid_argument{"UnknownIntegrationAction"};
    }

    options.neovim = std::string_view{arguments[1]} == "neovim";
    options.provider = options.neovim ? AgentProvider::unknown : providerNamed(arguments[1]);
    if (!options.neovim && options.provider == AgentProvider::unknown) {
      throw std::invalid_argument{"UnknownHookAgent"};
    }

    for (std::size_t index = 2; index < arguments.size(); ++index) {
      const std::string_view option = arguments[index];
      if (option == "--legacy" && options.action == IntegrationAction::uninstall && !options.neovim) {
        options.legacy = true;
        continue;
      }

      if (option != "--settings" || index + 1 >= arguments.size()) {
        throw std::invalid_argument{"UnknownIntegrationOption"};
      }

      options.settings = arguments[++index];
      if (!options.settings.starts_with('/')) {
        throw std::invalid_argument{"RelativeSettingsPath"};
      }
    }

    if (options.legacy && !options.settings.empty()) {
      throw std::invalid_argument{"UnknownIntegrationOption"};
    }

    return options;
  }

}

namespace telar::runtime::cli::integration {

  HookSettings::HookSettings(Memory& memory, Provider provider, std::string_view executable)
      : memory_(memory),
        provider_(provider),
        marker_{memory, " hook "},
        command_{memory},
        worktree_command_{memory} {
    if (executable.contains('\'')) {
      throw std::invalid_argument{"Unsupported integration executable path"};
    }

    marker_.append(provider.name);
    worktree_command_.assign("telar_hook_bin=${TELAR_BIN_PATH:-'");
    worktree_command_.append(executable);
    worktree_command_.append("'}; exec \"$telar_hook_bin\"");
    worktree_command_.append(marker_);
    command_.assign("[ -n \"$TELAR_PANE_ID\" ] && [ -n \"$TELAR_PANE_GENERATION\" ] || exit 0; ");
    command_.append(worktree_command_);
  }

  bool HookSettings::installed(const JsonNode<Memory>& settings, std::string_view event) const noexcept {
    const auto* hooks = settings.find("hooks");
    const auto* entries = hooks == nullptr ? nullptr : hooks->find(event);
    if (entries == nullptr || entries->kind() != JsonKind::array) {
      return false;
    }

    return std::ranges::any_of(entries->children(), [&](const auto& entry) {
      return findHook(entry) != nullptr;
    });
  }

  bool HookSettings::install(JsonNode<Memory>& settings) const {
    bool changed = false;

    if (provider_.flat_hooks && settings.find("version") == nullptr) {
      settings.setLiteral("version", "1");
      changed = true;
    }

    if (const auto* hooks = settings.find("hooks"); hooks && hooks->kind() != JsonKind::object) {
      throw CommandError{"SettingsFieldNotAnObject"};
    }

    auto& hooks = settings.ensure("hooks", JsonKind::object);

    changed = installEvents(hooks, provider_.events, command_, provider_.timeout) || changed;
    changed = installEvents(hooks, provider_.worktree_events, worktree_command_, worktree_timeout) || changed;
    return changed;
  }

  bool HookSettings::uninstall(JsonNode<Memory>& settings) const {
    auto* hooks = settings.findMut("hooks");
    if (hooks == nullptr || hooks->kind() != JsonKind::object) {
      return false;
    }

    const bool lifecycle_changed = removeEvents(*hooks, provider_.events);
    const bool worktrees_changed = removeEvents(*hooks, provider_.worktree_events);

    return lifecycle_changed || worktrees_changed;
  }

  bool HookSettings::isOwnCommand(const JsonNode<Memory>& hook) const noexcept {
    const auto* command = hook.find("command");

    return command != nullptr && command->kind() == JsonKind::string && command->text().ends_with(marker_);
  }

  template <typename Node>
  tbc::view<Node*, tbc::lt::a> HookSettings::findHook(tbc::view<Node&, tbc::lt::a> entry) const noexcept {
    if (provider_.flat_hooks) {
      return isOwnCommand(entry) ? &entry : nullptr;
    }

    // A const entry is searched through its const accessors, a mutable one through its mutable ones.
    auto* hooks = [&] {
      if constexpr (std::is_const_v<Node>) {
        return entry.find("hooks");
      } else {
        return entry.findMut("hooks");
      }
    }();
    if (hooks == nullptr || hooks->kind() != JsonKind::array) {
      return nullptr;
    }

    const auto candidates = [&] {
      if constexpr (std::is_const_v<Node>) {
        return hooks->children();
      } else {
        return hooks->childrenMut();
      }
    }();

    for (auto& hook : candidates) {
      if (isOwnCommand(hook)) {
        return &hook;
      }
    }

    return nullptr;
  }

  bool HookSettings::installEvents(JsonNode<Memory>& hooks, std::span<const std::string_view> events, std::string_view command, std::string_view timeout) const {
    bool changed = false;

    for (const auto event : events) {
      if (const auto* entries = hooks.find(event); entries && entries->kind() != JsonKind::array) {
        throw CommandError{"SettingsFieldNotAnArray"};
      }

      auto& entries = hooks.ensure(event, JsonKind::array);
      bool present = false;

      for (auto& entry : entries.childrenMut()) {
        auto* hook = findHook(entry);
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

  JsonNode<Memory> HookSettings::newEntry(std::string_view command, std::string_view timeout) const {
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

  bool HookSettings::removeOwnCommands(JsonNode<Memory>& commands, bool& changed) const {
    for (std::size_t command = 0; command < commands.children().size();) {
      if (isOwnCommand(commands.children()[command])) {
        commands.erase(command);
        changed = true;
      } else {
        ++command;
      }
    }

    return commands.children().empty();
  }

  bool HookSettings::removeEvents(JsonNode<Memory>& hooks, std::span<const std::string_view> events) const {
    bool changed = false;

    for (const auto event : events) {
      auto* entries = hooks.findMut(event);
      if (entries == nullptr || entries->kind() != JsonKind::array) {
        continue;
      }

      for (std::size_t index = 0; index < entries->children().size();) {
        auto& entry = entries->childrenMut()[index];
        bool empty = false;

        if (provider_.flat_hooks) {
          empty = isOwnCommand(entry);
          changed = empty || changed;
        } else if (auto* commands = entry.findMut("hooks"); commands != nullptr && commands->kind() == JsonKind::array) {
          empty = removeOwnCommands(*commands, changed);
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

}
