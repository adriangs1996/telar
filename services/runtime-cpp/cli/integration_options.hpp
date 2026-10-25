#pragma once

#include "../agents/provider.hpp"

namespace telar::runtime::cli {

enum class IntegrationAction { install,
                               uninstall,
                               status };

struct IntegrationOptions {
  IntegrationAction action = IntegrationAction::status;
  AgentProvider provider = AgentProvider::unknown;
  std::string_view settings;
  bool legacy = false;

  static IntegrationOptions parse(std::span<char *const> arguments) {
    if (arguments.size() < 2) {
      throw std::invalid_argument{"Expected integration install|uninstall|status AGENT"};
    }

    IntegrationOptions options;
    const std::string_view action = arguments[0];
    if (action == "install") {
      options.action = IntegrationAction::install;
    } else if (action == "uninstall") {
      options.action = IntegrationAction::uninstall;
    } else if (action != "status") {
      throw std::invalid_argument{"Unknown integration action"};
    }

    options.provider = providerNamed(arguments[1]);
    if (options.provider == AgentProvider::unknown) {
      throw std::invalid_argument{"Unknown integration agent"};
    }

    for (std::size_t index = 2; index < arguments.size(); ++index) {
      const std::string_view option = arguments[index];
      if (option == "--legacy" && options.action == IntegrationAction::uninstall) {
        options.legacy = true;
      } else if (option == "--settings" && index + 1 < arguments.size()) {
        options.settings = arguments[++index];
        if (!options.settings.starts_with('/')) {
          throw std::invalid_argument{"Integration settings path must be absolute"};
        }
      } else {
        throw std::invalid_argument{"Unknown integration option"};
      }
    }
    if (options.legacy && !options.settings.empty()) {
      throw std::invalid_argument{"Legacy integration cannot use an explicit settings path"};
    }

    return options;
  }
};

}
