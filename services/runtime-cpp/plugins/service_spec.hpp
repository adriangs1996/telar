#pragma once

#include "package.hpp"
#include <atomic>
#include <memory>

namespace telar::runtime::plugins {

struct ServiceSpec {
  std::uint8_t package_index = 0;
  std::uint64_t plugin_id = 0;
  PackageDigest digest{};
  std::uint64_t generation = 0;
  FixedText<PackageLimits::id_bytes> name;
  FixedText<PATH_MAX> entry;
  Capabilities declared;
  Capabilities granted;
  std::shared_ptr<std::atomic<bool>> permission;

  bool allows(Capability capability) const noexcept {
    return authorized() && declared.contains(capability) && granted.contains(capability);
  }

  bool authorized() const noexcept { return !permission || permission->load(std::memory_order_acquire); }

  bool traffic() const noexcept { return allows(Capability::traffic_observe) || allows(Capability::traffic_intercept) || allows(Capability::traffic_control) || allows(Capability::traffic_record); }

  bool stillAuthorized(Capabilities current) const noexcept { return current.containsAll(declared.intersection(granted)); }
};

}
