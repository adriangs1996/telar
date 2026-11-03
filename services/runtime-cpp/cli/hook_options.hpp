#pragma once

#include "telar_config/agents/provider.hpp"
#include <span>
#include <stdexcept>

namespace telar::runtime::cli {

struct HookOptions {
  AgentProvider provider;
  std::string_view socket;

  static HookOptions parse(std::span<char *> arguments) {
    if (arguments.empty()) {
      throw std::invalid_argument{"Missing hook agent"};
    }

    std::optional<AgentProvider> provider;
    for (const auto candidate : {AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode}) {
      if (describeProvider(candidate).name == arguments.front()) {
        provider = candidate;
      }
    }
    if (!provider) {
      throw std::invalid_argument{"Unknown hook agent"};
    }

    HookOptions options{.provider = *provider, .socket = {}};
    for (std::size_t index = 1; index < arguments.size(); index += 2) {
      if (std::string_view{arguments[index]} != "--socket" || index + 1 >= arguments.size()) {
        throw std::invalid_argument{"Unknown hook option"};
      }

      options.socket = arguments[index + 1];
    }

    return options;
  }
};

}
