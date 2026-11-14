export module telar.cli.machine;

import std;

export import telar.cli.machine_ssh;

import telar.cli.machine_ssh;

export import telar.cli.command_limit;

import telar.cli.window;

export import telar.cli.integration.settings;

export import telar.cli.runtime_observer;

export import telar.platform.paths;
export import telar.platform.process;
export import telar.platform.sha256;
import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.wire.clients;
import telar.platform.primitives;

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

    template <Allocator Memory>
    int runMachine(Memory& memory, const MachineOptions& options);
    extern template int runMachine<Memory>(Memory& memory, const MachineOptions& options);

  }
}
