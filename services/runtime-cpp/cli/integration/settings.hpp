#pragma once

#include "../integration_options.hpp"
#include "hook_settings.hpp"
#include "skills.hpp"

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
