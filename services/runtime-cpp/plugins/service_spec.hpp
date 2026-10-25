#pragma once

#include "package.hpp"

namespace telar::runtime::plugins {

struct ServiceSpec {
  std::uint8_t package_index = 0;
  std::uint64_t plugin_id = 0;
  PackageDigest digest{};
  std::uint64_t generation = 0;
  FixedText<PATH_MAX> entry;
  Capabilities declared;
  Capabilities granted;

  bool allows(Capability capability) const noexcept {
    return declared.contains(capability) && granted.contains(capability);
  }
};

}
