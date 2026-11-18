export module telar.cli.machine;

import std;

import telar.cli.machine_ssh;

import telar.cli.window;

import telar.base.memory.allocators;
import telar.machines;
import telar.base.ds;
import telar.cli.command_limit;

// Interface: machines/setup.cppm
export {
  namespace telar::runtime::cli::machine {

    struct Target {
      Text label;
      Text destination;
      ds::Option<MachineProfile> saved;
    };

    Target resolve(Memory& memory, const MachineProfiles& profiles, const MachineOptions& options);

  }
}

// Interface: machine.cppm
export {
  namespace telar::runtime::cli {

    int runMachine(Memory& memory, const MachineOptions& options);

  }
}
