#pragma once

#include "arguments.hpp"
#include "telar_config/agents/provider.hpp"

namespace telar::runtime::cli {

enum class IntegrationAction { install,
                               uninstall,
                               status };

struct IntegrationOptions {
  IntegrationAction action = IntegrationAction::status;
  AgentProvider provider = AgentProvider::unknown;
  std::string_view settings;
  bool legacy = false;

  // Zig's `IntegrationOptions.parse`, with its error names.
  static IntegrationOptions parse(std::span<char *const> arguments) {
    if (arguments.size() < 2) {
      usage("MissingIntegrationArguments");
    }

    IntegrationOptions options;
    const std::string_view action = arguments[0];
    if (action == "install") {
      options.action = IntegrationAction::install;
    } else if (action == "uninstall") {
      options.action = IntegrationAction::uninstall;
    } else if (action != "status") {
      usage("UnknownIntegrationAction");
    }

    options.provider = providerNamed(arguments[1]);
    if (options.provider == AgentProvider::unknown) {
      usage("UnknownHookAgent");
    }

    for (std::size_t index = 2; index < arguments.size(); ++index) {
      const std::string_view option = arguments[index];
      if (option == "--legacy" && options.action == IntegrationAction::uninstall) {
        options.legacy = true;
        continue;
      }

      if (option != "--settings" || index + 1 >= arguments.size()) {
        usage("UnknownIntegrationOption");
      }

      options.settings = arguments[++index];
      if (!options.settings.starts_with('/')) {
        usage("RelativeSettingsPath");
      }
    }

    if (options.legacy && !options.settings.empty()) {
      usage("UnknownIntegrationOption");
    }

    return options;
  }
};

}
