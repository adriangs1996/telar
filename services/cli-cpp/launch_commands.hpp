#pragma once

#include "telar_base/memory/allocator.hpp"
#include <span>

namespace telar::runtime::cli {

using Dispatch = int (*)(std::span<char *const>);

int runMachineCommand(BudgetAllocator<SystemAllocator> &memory, std::span<char *const> words);
int runCliCommand(std::span<char *const> words);
int runWindowCommand(BudgetAllocator<SystemAllocator> &memory, std::span<char *const> words, bool gui);
int dispatchMachine(std::span<char *const> words, Dispatch dispatch);
int dispatchArguments(std::span<char *const> words, Dispatch dispatch);

}
