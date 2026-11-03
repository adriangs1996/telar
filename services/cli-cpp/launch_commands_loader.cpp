#include "command_error.hpp"
#include "launch_commands.hpp"
#include "telar_platform/executable_path.hpp"
#include <dlfcn.h>
#include <string>

namespace telar::runtime::cli {
namespace {

// Hooks never load machine installers, JSON filters or window startup code.
// The module is a sibling of the real executable, including through CLI links.
void *launchModule() {
  static void *const module = [] {
    const ExecutablePath path{"telar-launch.so"};
    auto *handle = ::dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
      throw CommandError{std::string{"Cannot load telar-launch.so beside telar: "} + ::dlerror()};
    }

    const auto abi = reinterpret_cast<unsigned (*)()>(::dlsym(handle, "telarLaunchAbi"));
    constexpr unsigned expected_abi = 1;
    if (!abi || abi() != expected_abi) {
      ::dlclose(handle);
      throw CommandError{"Incompatible telar-launch.so; install it from the same build as telar"};
    }

    return handle;
  }();
  return module;
}

template <typename Function>
Function entry(const char *name) {
  auto *symbol = ::dlsym(launchModule(), name);
  if (!symbol) {
    throw CommandError{std::string{"Incompatible telar-launch.so: "} + ::dlerror()};
  }

  return reinterpret_cast<Function>(symbol);
}

}

int runMachineCommand(BudgetAllocator<SystemAllocator> &memory, std::span<char *const> words) {
  return entry<decltype(&runMachineCommand)>("telarLaunchMachine")(memory, words);
}

int runCliCommand(std::span<char *const> words) {
  return entry<decltype(&runCliCommand)>("telarLaunchCli")(words);
}

int runWindowCommand(BudgetAllocator<SystemAllocator> &memory, std::span<char *const> words, bool gui) {
  return entry<decltype(&runWindowCommand)>("telarLaunchWindow")(memory, words, gui);
}

int dispatchMachine(std::span<char *const> words, Dispatch dispatch) {
  return entry<decltype(&dispatchMachine)>("telarLaunchMachineDispatch")(words, dispatch);
}

int dispatchArguments(std::span<char *const> words, Dispatch dispatch) {
  return entry<decltype(&dispatchArguments)>("telarLaunchArguments")(words, dispatch);
}

}
