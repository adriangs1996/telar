#pragma once

#include "config_receive.hpp"
#include "machine_ssh.hpp"
#include "machines/setup.hpp"

namespace telar::runtime::cli {

template <Allocator Memory>
int runMachine(Memory &memory, const MachineOptions &options) {
  if (options.action == MachineOptions::Action::receive_config) {
    return config_receive::run();
  }

  const auto path = machine::profilesPath();
  try {
    const auto profiles = machine::load(memory, path);
    switch (options.action) {
    case MachineOptions::Action::list:
      return machine::list(memory, profiles, options.json);
    case MachineOptions::Action::setup:
      return machine::setup(memory, options);
    case MachineOptions::Action::check: {
      const auto row = profiles.find(options.label);
      if (!row) {
        throw machines::MachineFailure{machines::MachineError::unknown_machine};
      }

      return machine::check(memory, profiles.rows()[*row], options.json);
    }

    case MachineOptions::Action::add: {
      const auto profile = machine::newProfile(profiles, options);
      if (options.check && !options.setup) {
        const auto status = machine::check(memory, profile, options.json);
        if (status != 0) {
          return status;
        }
      }

      break;
    }

    default:
      break;
    }

    machine::update(memory, path, [&](machines::MachineProfiles &saved) { machine::change(saved, options); });
    if (options.action == MachineOptions::Action::add && options.setup) {
      return machine::setup(memory, options);
    }

    return 0;
  } catch (const std::exception &error) {
    return machine::report(error);
  }
}

}
