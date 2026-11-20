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

  namespace {

    // A file's directory and its name in it.
    struct PathParts {
      std::string_view directory;
      std::string_view name;
    };

    tbc::val_a<ds::String<Memory>> joinPath(tbc::mut_a<Memory> memory, PathParts parts) {
      ds::String<Memory> path{memory, parts.directory};

      path.push('/');
      path.append(parts.name);
      if (path.size() >= PATH_MAX || path.view().contains('\0')) {
        throw std::length_error{"Invalid integration file path"};
      }

      return path;
    }

  }

  tbc::val_a<ds::Option<ds::String<Memory>>> read(tbc::mut_a<Memory> memory, const ds::String<Memory>& path, std::size_t maximum_bytes) {
    FileDescriptor file{::open(path.data(), combineFlags(O_RDONLY, O_CLOEXEC, O_NONBLOCK, O_NOCTTY))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    if (!file) {
      if (sys::lastError() == ENOENT) {
        return ds::none;
      }

      throw SystemError{"Read integration file"};
    }

    struct stat state{};
    if (::fstat(file.get(), &state) == 0 && std::cmp_greater_equal(state.st_size, maximum_bytes)) {
      throw CommandError{"StreamTooLong"};
    }

    return readFileContents(memory, file.get(), maximum_bytes - 1);
  }

  namespace {

    void createParents(const ds::String<Memory>& path) {
      constexpr mode_t directory_mode = 0777;
      ds::Array<char, PATH_MAX> directory{};
      if (path.size() >= directory.size() || path.view().contains('\0')) {
        throw std::length_error{"Invalid integration file path"};
      }

      std::ranges::copy(path.view(), directory.dataMut());
      for (std::size_t index = 1; index < path.size(); ++index) {
        if (directory[index] == '/') {
          directory.atMut(index) = '\0';
          if (::mkdir(directory.data(), directory_mode) != 0 && sys::lastError() != EEXIST) {
            throw SystemError{"Create integration directory"};
          }

          directory.atMut(index) = '/';
        }
      }
    }

    void write(Memory& memory, const ds::String<Memory>& path, std::string_view source, bool preserve_settings) {
      constexpr mode_t permission_bits = 07777;
      ds::String<Memory> target{memory, path};
      ds::Option<mode_t> permissions;

      if (preserve_settings) {
        ds::Array<char, PATH_MAX> resolved{};
        if (::realpath(path.data(), resolved.dataMut()) != nullptr) {
          target.assign(resolved.data());
        }

        struct stat state{};
        if (::stat(target.data(), &state) == 0) {
          permissions = static_cast<mode_t>(state.st_mode & permission_bits);
        }
      }

      resolveAbsolutePath(target);
      createParents(target);
      const auto separator = target.view().rfind('/');
      const ds::String<Memory> parent{memory, std::string_view{target.data(), separator == 0 ? 1 : separator}};
      FileDescriptor directory{::open(parent.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
      if (!directory) {
        throw SystemError{"Open integration directory"};
      }

      const auto name = std::string_view{target}.substr(separator + 1);
      // The file takes the text as bytes, whose size the text gives.
#pragma clang unsafe_buffer_usage begin
      const std::span<const std::uint8_t> bytes{reinterpret_cast<const std::uint8_t*>(source.data()), source.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): bytes may alias text, and no cast-free view reads text as bytes
#pragma clang unsafe_buffer_usage end
      if (const int error = writePrivateFile(directory.get(), name, bytes, PrivateFileMode::replace)) {
        throw SystemError{"Publish integration file", error};
      }

      if (permissions && ::chmod(target.data(), *permissions) != 0) {
        throw SystemError{"Restore integration settings permissions"};
      }
    }

    enum class Ownership : std::uint8_t {
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

    Ownership ownershipOf(bool present, bool owned) noexcept {
      if (!present) {
        return Ownership::absent;
      }

      return owned ? Ownership::owned : Ownership::foreign;
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
    constexpr ds::Array skills{
        Skill{.name = "telar", .header = telar_header, .marker = "<!-- telar-integration: skill telar -->\n", .text = assets::telar_skill},
        Skill{.name = "telar-coordinator", .header = coordinator_header, .marker = "<!-- telar-integration: skill telar-coordinator -->\n", .text = assets::coordinator_skill, .legacy_header = true},
    };

    tbc::val_a<ds::String<Memory>> skillPath(tbc::mut_a<Memory> memory, std::string_view root, const Skill& skill) {
      auto path = joinPath(memory, {.directory = root, .name = "skills"});

      path = joinPath(memory, {.directory = path, .name = skill.name});
      return joinPath(memory, {.directory = path, .name = "SKILL.md"});
    }

    Ownership skillOwnership(const ds::String<Memory>& path, const Skill& skill) noexcept {
      // Enough of a skill file to hold its header and telar's marker.
      constexpr std::size_t skill_head_bytes = 1024;
      struct stat state{};
      if (::stat(path.data(), &state) != 0) {
        return sys::lastError() == ENOENT ? Ownership::absent : Ownership::foreign;
      }

      ds::Array<char, skill_head_bytes> buffer{};
      const auto contents = readRegularFile(path, buffer.viewMut());
      if (!contents) {
        return Ownership::foreign;
      }

      const auto header_size = skill.header.size();
      if (contents->contains(skill.marker) || (skill.legacy_header && contents->starts_with(skill.header) && contents->size() > header_size && (*contents)[header_size] == '\n')) {
        return Ownership::owned;
      }

      return Ownership::foreign;
    }

    void installSkills(Memory& memory, std::string_view root) {
      for (const auto& skill : skills) {
        const auto path = skillPath(memory, root, skill);
        if (skillOwnership(path, skill) == Ownership::foreign) {
          std::println("telar integration: skill {} at {} is not telar's; left untouched", skill.name, path.view());
          continue;
        }

        ds::String<Memory> contents{memory, skill.header};

        contents.append(skill.marker);
        contents.push('\n');
        contents.append(skill.text);
        write(memory, path, contents, false);
        std::println("telar integration: skill {} written to {}", skill.name, path.view());
      }
    }

    void reportSkills(Memory& memory, std::string_view root) {
      for (const auto& skill : skills) {
        const auto path = skillPath(memory, root, skill);

        std::println("skill {}: {} at {}", skill.name, ownershipName(skillOwnership(path, skill)), path.view());
      }
    }

    void removeSkills(Memory& memory, std::string_view root) noexcept {
      for (const auto& skill : skills) {
        try {
          const auto path = skillPath(memory, root, skill);
          if (skillOwnership(path, skill) == Ownership::owned) {
            ::unlink(path.data());
          }
        } catch (...) { // NOLINT(bugprone-empty-catch): removing the skills is best effort; one that stays is the user's to delete.
        }
      }
    }

    struct Extension {
      std::string_view noun;
      std::string_view marker;
      std::string_view source;

      static Extension describe(AgentProvider provider) {
        if (provider == AgentProvider::pi) {
          return {.noun = "extension", .marker = "// telar-integration: pi", .source = assets::pi_extension};
        }

        if (provider == AgentProvider::opencode) {
          return {.noun = "plugin", .marker = "// telar-integration: opencode", .source = assets::opencode_extension};
        }

        throw std::invalid_argument{"Provider does not use an integration extension"};
      }

      // The text lives in the memory it is written to, region `a`.
      tbc::val_a<ds::String<Memory>> render(tbc::mut_a<Memory> memory, std::string_view executable) const {
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

      static constexpr std::size_t maximum_bytes = std::size_t{64} * 1024;
    };

  }

  int extensionCommand(Memory& memory, const IntegrationOptions& options, const EnvironmentSource& environment, std::string_view executable) {
    const auto provider = Provider::describe(options.provider);
    const auto extension = Extension::describe(options.provider);
    const auto root = provider.root(memory, environment);
    const auto path = options.settings.empty() ? joinPath(memory, {.directory = root, .name = provider.file}) : ds::String<Memory>{memory, options.settings};
    const auto rendered = extension.render(memory, executable);
    const auto existing = read(memory, path, Extension::maximum_bytes);
    const bool owned = existing && existing->view().starts_with(extension.marker);

    if (options.action == IntegrationAction::status) {
      std::println("telar {}: {} at {}", extension.noun, ownershipName(ownershipOf(existing.hasValue(), owned)), path.view());
      reportSkills(memory, root);
      return 0;
    }

    if (existing && !owned && *existing != rendered) {
      const std::string_view action = options.action == IntegrationAction::install ? "exists and is not telar's" : "is not telar's";
      const std::string_view resolution = options.action == IntegrationAction::install ? "move it first" : "left untouched";

      std::println(stderr, "telar integration: {} {} {}; {}", path.view(), action, extension.noun, resolution);
      return 1;
    }

    if (options.action == IntegrationAction::install) {
      std::string_view state = "already present";

      if (!existing || *existing != rendered) {
        write(memory, path, rendered, false);
        state = existing ? "updated" : "installed";
      }

      std::println("telar integration: {} {} {} at {}", provider.name, extension.noun, state, path.view());
      installSkills(memory, root);
      return 0;
    }

    if (existing) {
      if (::unlink(path.data()) != 0) {
        throw SystemError{"Remove integration extension"};
      }

      std::println("telar integration: {} {} removed from {}", provider.name, extension.noun, path.view());
    } else {
      std::println("telar integration: {} {} not present at {}", provider.name, extension.noun, path.view());
    }

    removeSkills(memory, root);
    return 0;
  }

  template <EnvironmentLookup Environment>
  int runExtension(Memory& memory, const IntegrationOptions& options, const Environment& environment, std::string_view executable) {
    return extensionCommand(memory, options, environment, executable);
  }

  namespace {

    constexpr std::size_t maximum_settings_bytes = std::size_t{4} * 1024 * 1024;

    tbc::val_a<ds::Option<ds::String<Memory>>> legacySettings(tbc::mut_a<Memory> memory, Provider provider, const EnvironmentSource& environment) {
      if (provider.environment == nullptr || environment.lookup(provider.environment).empty() || environment.lookup("HOME").empty()) {
        return ds::none;
      }

      const auto current = joinPath(memory, {.directory = provider.root(memory, environment), .name = provider.file});
      auto legacy = joinPath(memory, {.directory = provider.root(memory, environment, true), .name = provider.file});
      ds::Array<char, PATH_MAX> legacy_path{};
      ds::Array<char, PATH_MAX> current_path{};

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
            std::println("telar integration: hooks remain in {}, which is not read while its directory variable is set; `telar integration uninstall {} --legacy` removes them", path.view(), provider.name);
            return true;
          }
        }
      }

      return false;
    }

    // The settings file the command reads: the one given, the legacy one, or the provider's.
    tbc::val_a<ds::Option<ds::String<Memory>>> settingsPath(tbc::mut_a<Memory> memory, const IntegrationOptions& options, Provider provider, const EnvironmentSource& environment) {
      if (!options.settings.empty()) {
        return ds::String<Memory>{memory, options.settings};
      }

      if (!options.legacy) {
        return joinPath(memory, {.directory = provider.root(memory, environment), .name = provider.file});
      }

      return legacySettings(memory, provider, environment);
    }

    void reportHookEvents(const HookSettings& hooks, const JsonNode<Memory>& settings, Provider provider) {
      for (const auto events : {provider.events, provider.worktree_events}) {
        for (const auto event : events) {
          std::println("{}: {}", event, hooks.installed(settings, event) ? "installed" : "absent");
        }
      }
    }

    std::string_view hooksState(bool installing, bool changed) noexcept {
      if (installing) {
        return changed ? "installed" : "already present";
      }

      return changed ? "removed" : "not present";
    }

  }

  int settingsCommand(Memory& memory, const IntegrationOptions& options, const EnvironmentSource& environment, std::string_view executable) {
    const auto provider = Provider::describe(options.provider);
    const auto path = settingsPath(memory, options, provider, environment);
    if (!path) {
      // Only a legacy file goes missing: the others are named whether they exist or not.
      std::println(stderr, "telar integration: no {} settings under the home directory differ from the ones in use", provider.name);
      return 1;
    }

    const HookSettings hooks{memory, provider, executable};
    const auto source = read(memory, *path, maximum_settings_bytes);
    ds::Option<JsonNode<Memory>> settings;

    try {
      settings.emplace(JsonNode<Memory>::parse(memory, source ? std::string_view{*source} : "{}"));
    } catch (const std::exception&) {
      std::println(stderr, "telar integration: {} is not valid JSON", path->view());
      return 1;
    }

    if (settings->kind() != JsonKind::object) {
      std::println(stderr, "telar integration: {} must contain a JSON object", path->view());
      return 1;
    }

    const auto separator = path->view().rfind('/');
    const auto root = separator == std::string_view::npos ? std::string_view{} : path->view().substr(0, separator == 0 ? 1 : separator);
    if (root.empty()) {
      throw std::invalid_argument{"Invalid integration settings path"};
    }

    if (options.action == IntegrationAction::status) {
      reportHookEvents(hooks, *settings, provider);
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
      write(memory, *path, settings->format(), true);
    }

    std::println("telar integration: {} hooks {} in {}", provider.name, hooksState(installing, changed), path->view());
    if (installing) {
      installSkills(memory, root);
      if (!provider.launch_note.empty()) {
        std::println("telar integration: {}", provider.launch_note);
      }
    } else if (changed || !options.legacy) {
      removeSkills(memory, root);
    }

    return 0;
  }

  template <EnvironmentLookup Environment>
  int runSettings(Memory& memory, const IntegrationOptions& options, const Environment& environment, std::string_view executable) {
    return settingsCommand(memory, options, environment, executable);
  }

  namespace {

    // The first line of every file telar's Neovim plugin writes: only those are replaced or removed.
    constexpr std::string_view neovim_marker = "-- telar-integration: neovim\n";
    constexpr std::size_t maximum_neovim_file_bytes = std::size_t{256} * 1024;

    // The directories of the plugin's files, each once.
    struct NeovimDirectories {
      ds::Array<std::string_view, std::size(assets::neovim_files)> names{};
      std::size_t count = 0;
    };

    constexpr NeovimDirectories neovimDirectories() {
      NeovimDirectories directories;

      for (const auto& file : assets::neovim_files) {
        const auto directory = file.path.substr(0, file.path.rfind('/'));
        if (std::ranges::find(directories.names.view().first(directories.count), directory) == directories.names.view().first(directories.count).end()) {
          directories.names.atMut(directories.count++) = directory;
        }
      }

      return directories;
    }

    constexpr auto neovim_directories = neovimDirectories();

    // $XDG_DATA_HOME/$NVIM_APPNAME/site, as Neovim's stdpath("data") .. "/site" names it.
    template <EnvironmentLookup Environment>
    tbc::val_a<ds::String<Memory>> neovimSite(tbc::mut_a<Memory> memory, const Environment& environment) {
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

      return joinPath(memory, {.directory = joinPath(memory, {.directory = data, .name = application.empty() ? "nvim" : application}), .name = "site"});
    }

    bool packagedNeovimFile(std::string_view directory, std::string_view name) noexcept {
      return std::ranges::any_of(assets::neovim_files, [&](const auto& file) {
        return file.path.starts_with(directory) && file.path.size() == directory.size() + 1 + name.size() && file.path.ends_with(name);
      });
    }

    // The telar-owned files in one of the package's directories that the package no longer has.
    void removeStaleNeovimFilesIn(Memory& memory, std::string_view site, std::string_view directory) {
      const auto path = joinPath(memory, {.directory = site, .name = directory});
      // A directory that cannot be opened or read throws, and the caller skips it.
      DirectoryStream listing{FileDescriptor{::open(path.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC))}}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic

      while (const auto* entry = listing.next()) {
        const std::string_view name{std::data(entry->d_name)};
        if (!name.ends_with(".lua")) {
          continue;
        }

        const auto stale = joinPath(memory, {.directory = path, .name = name});
        const auto existing = packagedNeovimFile(directory, name) ? ds::Option<ds::String<Memory>>{} : read(memory, stale, maximum_neovim_file_bytes);
        if (existing && existing->view().starts_with(neovim_marker)) {
          ::unlink(stale.data());
          std::println("telar integration: neovim {} removed, no longer part of the plugin", stale.view());
        }
      }
    }

    // The telar-owned files under the package's directories that the package no longer has.
    void removeStaleNeovimFiles(Memory& memory, std::string_view site) noexcept {
      for (const auto directory : neovim_directories.names.view().first(neovim_directories.count)) {
        try {
          removeStaleNeovimFilesIn(memory, site, directory);
        } catch (...) { // NOLINT(bugprone-empty-catch): the stale files are removed best effort; a directory that fails leaves its files.
        }
      }
    }

    // Reports each of the plugin's files, or a file another tool or the user wrote; whether one is.
    bool checkNeovimFiles(Memory& memory, const IntegrationOptions& options, std::string_view site) {
      bool foreign = false;

      for (const auto& file : assets::neovim_files) {
        const auto path = joinPath(memory, {.directory = site, .name = file.path});
        const auto existing = read(memory, path, maximum_neovim_file_bytes);
        const auto ownership = ownershipOf(existing.hasValue(), existing && existing->view().starts_with(neovim_marker));

        if (options.action == IntegrationAction::status) {
          std::println("neovim {}: {} at {}", file.path, ownershipName(ownership), path.view());
        } else if (ownership == Ownership::foreign) {
          std::println(stderr, "telar integration: {} is not telar's neovim plugin; {}", path.view(), options.action == IntegrationAction::install ? "move it first" : "left untouched");
          foreign = true;
        }
      }

      return foreign;
    }

    // Installs or removes each of the plugin's files that telar owns or that is absent.
    void applyNeovimFiles(Memory& memory, const IntegrationOptions& options, std::string_view site) {
      for (const auto& file : assets::neovim_files) {
        const auto path = joinPath(memory, {.directory = site, .name = file.path});
        const auto existing = read(memory, path, maximum_neovim_file_bytes);
        if (existing && !existing->view().starts_with(neovim_marker)) {
          continue;
        }

        if (options.action == IntegrationAction::uninstall) {
          if (existing && ::unlink(path.data()) != 0) {
            throw SystemError{"Remove integration file"};
          }

          std::println("telar integration: neovim {} {} {}", file.path, existing ? "removed from" : "not present at", path.view());
          continue;
        }

        ds::String<Memory> contents{memory, neovim_marker};
        std::string_view state = "already present";

        contents.append(file.text);
        if (!existing || *existing != contents) {
          write(memory, path, contents, false);
          state = existing ? "updated" : "installed";
        }

        std::println("telar integration: neovim {} {} at {}", file.path, state, path.view());
      }
    }

  }

  template <EnvironmentLookup Environment>
  int runNeovim(Memory& memory, const IntegrationOptions& options, const Environment& environment) {
    const auto site = options.settings.empty() ? neovimSite(memory, environment) : ds::String<Memory>{memory, options.settings};
    // A file another tool or the user wrote stops the whole install, before anything changes.
    const bool foreign = checkNeovimFiles(memory, options, site);
    if (options.action == IntegrationAction::status || (foreign && options.action == IntegrationAction::install)) {
      return foreign ? 1 : 0;
    }

    applyNeovimFiles(memory, options, site);
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
    command_.assign(R"([ -n "$TELAR_PANE_ID" ] && [ -n "$TELAR_PANE_GENERATION" ] || exit 0; )");
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
      settings.setLiteral({.name = "version", .value = "1"});
      changed = true;
    }

    if (const auto* hooks = settings.find("hooks"); (hooks != nullptr) && hooks->kind() != JsonKind::object) {
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
  tbc::val_a<Node*> HookSettings::findHook(tbc::mut_a<Node> entry) const noexcept {
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
      if (const auto* entries = hooks.find(event); (entries != nullptr) && entries->kind() != JsonKind::array) {
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
          hook->setString({.name = "command", .value = command});
          changed = true;
        }
      }

      if (!present) {
        entries.append(newEntry({.command = command, .timeout = timeout}));
        changed = true;
      }
    }

    return changed;
  }

  JsonNode<Memory> HookSettings::newEntry(HookCommand command) const {
    const auto hook = [&] {
      JsonNode<Memory> node{memory_};

      if (!provider_.flat_hooks) {
        node.setString({.name = "type", .value = "command"});
      }

      node.setString({.name = "command", .value = command.command});
      node.setLiteral({.name = "timeout", .value = command.timeout});
      return node;
    };

    if (provider_.flat_hooks) {
      return hook();
    }

    JsonNode<Memory> entry{memory_};

    entry.ensure("hooks", JsonKind::array).append(hook());
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
