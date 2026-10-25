#pragma once

#include "../../text/json.hpp"
#include "../integration_options.hpp"
#include "provider.hpp"
#include "skills.hpp"

namespace telar::runtime::cli::integration {

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

  template <Allocator Memory>
  String<Memory> render(Memory &memory, std::string_view executable) const {
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
