// The commands main dispatches to start a window, run one on another machine, install the
// CLI or check a completion spec. They sit above telar.cli.machine and telar.cli.window.
export module telar.cli.launch_commands;

import std;

import telar.base.memory.allocators;

export {
  namespace telar::runtime::cli {

    using Dispatch = int (*)(std::span<char* const>);

    int runMachineCommand(Memory& memory, std::span<char* const> words);
    int runCliCommand(std::span<char* const> words);
    int runCompletionsCommand(Memory& memory, std::span<char* const> words);
    int runWindowCommand(Memory& memory, std::span<char* const> words, bool gui);
    int dispatchMachine(std::span<char* const> words, Dispatch dispatch);
    // Decodes the words `dispatch-argv` carries, into `memory`, and runs them.
    int dispatchArguments(Memory& memory, std::span<char* const> words, Dispatch dispatch);

  }
}
