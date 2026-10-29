#pragma once

#include "../text/utf8.hpp"
#include "../text/executable_name.hpp"
#include "../text/ascii.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <string_view>

namespace telar::runtime {

struct ProviderDescription {
  std::string_view name;
  std::string_view display_name;
  std::string_view placeholder;
  AgentAttachmentMarkers attachments;
  std::array<std::string_view, 2> process_names;
};

inline ProviderDescription describeProvider(AgentProvider provider) noexcept {
  switch (provider) {
  case AgentProvider::claude:
    return {.name = "claude", .display_name = "Claude Code", .placeholder = "New Claude Code session", .attachments = AgentAttachmentMarkers::stable_number, .process_names = {"claude", "claude-code"}};
  case AgentProvider::codex:
    return {.name = "codex", .display_name = "Codex", .placeholder = "New Codex session", .attachments = AgentAttachmentMarkers::ordered, .process_names = {"codex", {}}};
  case AgentProvider::pi:
    return {.name = "pi", .display_name = "Pi", .placeholder = "New Pi session", .attachments = AgentAttachmentMarkers::pasted_path, .process_names = {"pi", {}}};
  case AgentProvider::cursor:
    return {.name = "cursor", .display_name = "Cursor Agent", .placeholder = "New Cursor Agent session", .attachments = AgentAttachmentMarkers::none, .process_names = {"cursor-agent", {}}};
  case AgentProvider::opencode:
    return {.name = "opencode", .display_name = "OpenCode", .placeholder = "New OpenCode session", .attachments = AgentAttachmentMarkers::none, .process_names = {"opencode", {}}};
  default:
    return {.name = "", .display_name = "", .placeholder = "New agent session", .attachments = AgentAttachmentMarkers::none, .process_names = {}};
  }
}

inline AgentProvider builtinProviderFromExecutable(std::string_view name) noexcept {
  const auto stem = withoutExecutableSuffix(name);
  for (const auto provider : {AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode}) {
    for (const auto process : describeProvider(provider).process_names) {
      if (!process.empty() && asciiEqualIgnoreCase(stem, process)) {
        return provider;
      }
    }
  }

  return AgentProvider::unknown;
}

inline AgentProvider providerNamed(std::string_view name) noexcept {
  for (const auto provider : {AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode}) {
    if (describeProvider(provider).name == name) {
      return provider;
    }
  }

  return AgentProvider::unknown;
}

}
