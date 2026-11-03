#pragma once

#include "telar_platform/sha256.hpp"
#include "telar_plugins/package_inspection.hpp"

namespace telar::runtime::plugins {

using PackageInspector = PackageInspection<Sha256>;

}
