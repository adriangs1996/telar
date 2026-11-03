#pragma once

#include "telar_lua/local_modules.hpp"

namespace telar::runtime::config {

using LocalModules = lua::LocalModules<lua::ModuleDomain::configuration>;

}
