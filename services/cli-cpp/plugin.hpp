#pragma once

#include "command_error.hpp"
#include "command_io.hpp"
#include "plugin_options.hpp"
#include "telar_plugins/inspection.hpp"
#include "telar_plugins/package_installation.hpp"
#include "telar_plugins/paths.hpp"
#include "telar_plugins/trust_update.hpp"

namespace telar::runtime::cli {

// Zig's `grantedCapabilities`: the manifest's, or the requested ones, each
// declared there and named once.
inline plugins::Capabilities grantedCapabilities(const plugins::Manifest &manifest, const PluginOptions &options) {
  if (options.capability_count == 0) {
    return manifest.capabilities;
  }

  plugins::Capabilities granted;
  for (const auto capability : std::span{options.capabilities}.first(options.capability_count)) {
    if (!manifest.capabilities.contains(capability)) {
      throw std::runtime_error{"CapabilityNotDeclared"};
    }

    granted.insert(capability);
  }

  return granted;
}

template <Allocator Memory, EnvironmentLookup Environment>
void executePlugin(Memory &memory, const PluginOptions &options, const Environment &environment) {
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

// As Zig's `plugin.run`, a failure after the arguments parsed prints
// `error: NAME` with Zig's error name.
template <Allocator Memory, EnvironmentLookup Environment>
void runPlugin(Memory &memory, const PluginOptions &options, const Environment &environment) {
  try {
    executePlugin(memory, options, environment);
  } catch (const SystemError &error) {
    throw CommandError{systemErrorName(error.code())};
  } catch (const std::exception &error) {
    throw CommandError{error.what()};
  }
}

}
