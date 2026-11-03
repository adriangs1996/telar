#pragma once

#include "../plugins/package_installation.hpp"
#include "../plugins/paths.hpp"
#include "../plugins/trust_update.hpp"
#include "plugin_options.hpp"
#include "telar_plugins/inspection.hpp"

namespace telar::runtime::cli {

inline plugins::Capabilities grantedCapabilities(const plugins::Manifest &manifest, const PluginOptions &options) {
  if (!options.explicit_capabilities) {
    return manifest.capabilities;
  }
  for (unsigned value = 0; value < static_cast<unsigned>(plugins::Capability::count); ++value) {
    const auto capability = static_cast<plugins::Capability>(value);
    if (options.capabilities.contains(capability) && !manifest.capabilities.contains(capability)) {
      throw std::invalid_argument{"Plugin capability is not declared"};
    }
  }
  return options.capabilities;
}

template <Allocator Memory, EnvironmentLookup Environment>
void runPlugin(Memory &memory, const PluginOptions &options, const Environment &environment) {
  if (options.action == PluginAction::untrust) {
    plugins::revokeTrust(memory, options.path, plugins::Paths::trust(memory, environment));
    constexpr std::string_view message = "telar plugin trust revoked\n";
    const auto written = writeDescriptor(STDOUT_FILENO, {reinterpret_cast<const std::uint8_t *>(message.data()), message.size()});
    if (written != 0) { throw SystemError{"Write plugin command output", written}; }
    return;
  }
  const auto package = plugins::PackageInspector::inspect(memory, options.path);
  String<Memory> output{AllocatorRef<char, Memory>{memory}};
  switch (options.action) {
  case PluginAction::inspect:
    plugins::appendInspection(output, package);
    break;
  case PluginAction::install: {
    const auto destination = plugins::Paths::installation(memory, environment, package);
    plugins::PackageInstallation{memory}.install(package, destination);
    output = "telar plugin installed: ";
    output += destination;
    output += '\n';
    break;
  }
  case PluginAction::trust:
    plugins::updateTrust(memory, package, grantedCapabilities(package.manifest, options), plugins::Paths::trust(memory, environment));
    output = "telar plugin trust updated\n";
    break;
  case PluginAction::untrust:
    break;
  }

  const auto written = writeDescriptor(STDOUT_FILENO, {reinterpret_cast<const std::uint8_t *>(output.data()), output.size()});
  if (written != 0) {
    throw SystemError{"Write plugin command output", written};
  }
}

}
