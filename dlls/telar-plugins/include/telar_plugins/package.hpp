#pragma once

#include "telar_plugins/manifest.hpp"
#include <limits.h>

namespace telar::runtime::plugins {

struct Package {
  Manifest manifest;
  PackageDigest digest{};
  FixedText<PATH_MAX> root;
};

}
