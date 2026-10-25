#pragma once

#include "../lua/local_modules.hpp"

namespace telar::runtime::config {

using LocalModules = lua::LocalModules<lua::ModuleDomain::configuration>;

}
