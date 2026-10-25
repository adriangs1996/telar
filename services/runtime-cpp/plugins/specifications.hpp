#pragma once

#include "../memory/fixed_text.hpp"
#include "package_limits.hpp"
#include <span>

namespace telar::runtime::plugins {

struct ConfiguredPlugin {
  FixedText<PackageLimits::configured_path_bytes> path;
  bool enabled = true;
};

struct Specifications {
  std::array<ConfiguredPlugin, PackageLimits::configured> entries;
  std::size_t count = 0;

  std::span<const ConfiguredPlugin> configured() const noexcept {
    return std::span{entries}.first(count);
  }
};

}
