#pragma once

#include "family.hpp"
#include <span>

namespace telar::runtime::cli {

int runWindow(Family family, std::span<char *const> words);

}
