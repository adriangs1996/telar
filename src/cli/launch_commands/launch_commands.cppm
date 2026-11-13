// The commands main dispatches to start a window, run one on another machine, install the
// CLI or check a completion spec. They sit above telar.cli.machine and telar.cli.window.
export module telar.cli.launch_commands;

import std;

import telar.base.memory.allocators;

export {
  namespace telar::runtime::cli {

    using Dispatch = int (*)(std::span<char* const>);

    int runMachineCommand(BudgetAllocator<SystemAllocator>& memory, std::span<char* const> words);
    int runCliCommand(std::span<char* const> words);
    int runCompletionsCommand(std::span<char* const> words);
    int runWindowCommand(BudgetAllocator<SystemAllocator>& memory, std::span<char* const> words, bool gui);
    int dispatchMachine(std::span<char* const> words, Dispatch dispatch);
    int dispatchArguments(std::span<char* const> words, Dispatch dispatch);

  }
}
