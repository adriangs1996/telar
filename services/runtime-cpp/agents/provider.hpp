#pragma once

#include "../text/utf8.hpp"
#include "telar_client/serializers/telar_protocol.hpp"

namespace telar::runtime {

struct ProviderDescription {
  std::string_view name;
  std::string_view display_name;
  std::string_view placeholder;
  AgentAttachmentMarkers attachments;
};

inline ProviderDescription describeProvider(AgentProvider provider) noexcept {
  switch (provider) {
  case AgentProvider::claude:
    return {"claude", "Claude Code", "New Claude Code session", AgentAttachmentMarkers::stable_number};
  case AgentProvider::codex:
    return {"codex", "Codex", "New Codex session", AgentAttachmentMarkers::ordered};
  case AgentProvider::pi:
    return {"pi", "Pi", "New Pi session", AgentAttachmentMarkers::pasted_path};
  case AgentProvider::cursor:
    return {"cursor", "Cursor Agent", "New Cursor Agent session", AgentAttachmentMarkers::none};
  case AgentProvider::opencode:
    return {"opencode", "OpenCode", "New OpenCode session", AgentAttachmentMarkers::none};
  default:
    return {"", "", "New agent session", AgentAttachmentMarkers::none};
  }
}

inline AgentProvider providerNamed(std::string_view name) noexcept {
  for (auto provider : {AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode}) {
    if (describeProvider(provider).name == name) {
      return provider;
    }
  }

  return AgentProvider::unknown;
}

}
