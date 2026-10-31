#pragma once

#include "../platform/sha256.hpp"
#include "package_inspection.hpp"

namespace telar::runtime::plugins {

using PackageInspector = PackageInspection<Sha256>;

}
