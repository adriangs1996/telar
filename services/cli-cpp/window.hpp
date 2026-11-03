#pragma once

#include "family.hpp"
#include "routed_options.hpp"
#include <span>

namespace telar::runtime::cli {

int runWindow(Family family, std::span<char *const> words);

// Zig's `routed.run`: sends one window command to the client it names.
int runRouted(const RoutedOptions &options);

}
