#pragma once

#include "../plugins/capabilities.hpp"

namespace telar::runtime::cli {

enum class PluginAction { inspect,
                          install,
                          trust };

struct PluginOptions {
  PluginAction action;
  std::string_view path;
  plugins::Capabilities capabilities;
  bool explicit_capabilities = false;

  static PluginOptions parse(std::span<char *const> arguments) {
    if (arguments.size() < 2) {
      throw std::invalid_argument{"Expected plugin inspect|install|trust PATH [--capability NAME]"};
    }
    PluginOptions options{.action = parseAction(arguments[0]), .path = arguments[1], .capabilities = {}};
    for (std::size_t index = 2; index < arguments.size(); index += 2) {
      if (options.action != PluginAction::trust || std::string_view{arguments[index]} != "--capability" || index + 1 == arguments.size()) {
        throw std::invalid_argument{"Invalid plugin arguments"};
      }
      options.capabilities.insert(plugins::Capabilities::parseName(arguments[index + 1]));
      options.explicit_capabilities = true;
    }
    return options;
  }

private:
  static PluginAction parseAction(std::string_view action) {
    if (action == "inspect") {
      return PluginAction::inspect;
    }
    if (action == "install") {
      return PluginAction::install;
    }
    if (action == "trust") {
      return PluginAction::trust;
    }
    throw std::invalid_argument{"Unknown plugin action"};
  }
};

}
