#pragma once

#include "arguments.hpp"
#include "telar_plugins/capabilities.hpp"

namespace telar::runtime::cli {

enum class PluginAction { inspect,
                          install,
                          trust,
                          untrust };

struct PluginOptions {
  PluginAction action;
  std::string_view path;
  std::array<plugins::Capability, static_cast<std::size_t>(plugins::Capability::count)> capabilities{};
  std::size_t capability_count = 0;

  // Zig's `PluginOptions.parse`, with its error names; `untrust` is the C++
  // runtime's addition.
  static PluginOptions parse(std::span<char *const> arguments) {
    if (arguments.size() < 2) {
      usage("MissingPluginArguments");
    }

    PluginOptions options{.action = parseAction(arguments[0]), .path = arguments[1]};
    for (std::size_t index = 2; index < arguments.size(); index += 2) {
      if (std::string_view{arguments[index]} != "--capability" || index + 1 >= arguments.size()) {
        usage("InvalidPluginArguments");
      }

      if (options.capability_count == options.capabilities.size()) {
        usage("TooManyPluginCapabilities");
      }

      options.capabilities[options.capability_count++] = plugins::Capabilities::parseName(arguments[index + 1]);
    }

    if (options.action != PluginAction::trust && options.capability_count != 0) {
      usage("InvalidPluginArguments");
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
    if (action == "untrust") {
      return PluginAction::untrust;
    }
    usage("UnknownPluginAction");
  }
};

}
