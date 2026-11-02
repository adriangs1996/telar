#pragma once

#include "../plugins/service_spec.hpp"

namespace telar::runtime::traffic::recording {

struct Owner {
  std::uint64_t id = 0;
  plugins::PackageDigest digest{};
  std::shared_ptr<std::atomic<bool>> permission;

  static Owner package(const plugins::ServiceSpec &package) { return {package.plugin_id, package.digest, package.permission}; }
  bool authorized() const noexcept { return !permission || permission->load(std::memory_order_acquire); }
  bool matches(const Owner &other) const noexcept { return id == other.id && digest == other.digest; }
  bool canRead(const Owner &other) const noexcept { return id == 0 || matches(other); }
};

}
