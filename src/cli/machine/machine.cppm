export module telar.cli.machine;

import std;

import telar.cli.machine_ssh;

import telar.cli.window;

import telar.base.memory.allocators;
import telar.machines;

// Interface: machines/setup.cppm
export {
  namespace telar::runtime::cli::machine {

    struct Target {
      std::string label;
      std::string destination;
      std::optional<MachineProfile> saved;
    };

    Target resolve(const MachineProfiles& profiles, const MachineOptions& options);

  }
}

// Interface: machine.cppm
export {
  namespace telar::runtime::cli {

    int runMachine(Memory& memory, const MachineOptions& options);

  }
}
