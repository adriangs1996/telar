#pragma once

#include "package_snapshots.hpp"
#include "service_spec.hpp"
#include "telar_platform/process_environment.hpp"
#include "telar_plugins/package_registry.hpp"
#include "telar_plugins/paths.hpp"
#include "telar_plugins/trust_store.hpp"

namespace telar::runtime::plugins {

template <Allocator Memory>
class TapConfiguration {
public:
  template <EnvironmentLookup Environment>
  explicit TapConfiguration(Memory &memory, std::string_view directory, std::span<const ConfiguredPlugin> configured, const Environment &environment)
      : snapshots_(memory) {
    if (directory.empty()) {
      return;
    }

    const auto trust = loadTrust(memory, environment);
    const PackageRegistry registry{memory, directory, configured};
    for (const auto &package : registry.packages()) {
      const auto granted = trust.granted(package.manifest.id.view(), package.digest);
      const auto allowed = [&](Capability capability) { return package.manifest.capabilities.contains(capability) && granted.contains(capability); };
      if (!allowed(Capability::proxy_tap) && !allowed(Capability::traffic_observe) && !allowed(Capability::traffic_intercept) && !allowed(Capability::traffic_control) && !allowed(Capability::traffic_record)) {
        continue;
      }
      if (count_ == specifications_.size()) {
        throw std::invalid_argument{"Too many tap plugins"};
      }

      const auto copied = snapshots_.copy(package, count_);
      auto &specification = specifications_[count_];
      specification.package_index = static_cast<std::uint8_t>(count_);
      specification.plugin_id = stableId(copied.manifest.id.view());
      specification.digest = copied.digest;
      specification.generation = initial_generation;
      specification.name = copied.manifest.id;
      specification.declared = copied.manifest.capabilities;
      specification.granted = granted;
      String<Memory> entry{copied.root.view(), AllocatorRef<char, Memory>{memory}};
      entry += '/';
      entry += copied.manifest.entry.view();
      specification.entry.assign(entry);
      ++count_;
    }
  }

  std::span<const ServiceSpec> specifications() const noexcept { return std::span{specifications_}.first(count_); }

private:
  template <EnvironmentLookup Environment>
  static TrustStore loadTrust(Memory &memory, const Environment &environment) {
    return TrustStore::load(memory, Paths::trust(memory, environment));
  }

  static constexpr std::uint64_t initial_generation = 1;
  PackageSnapshots<Memory> snapshots_;
  std::array<ServiceSpec, Limits::workers> specifications_;
  std::size_t count_ = 0;
};

template <Allocator Memory, EnvironmentLookup Environment>
TapConfiguration(Memory &memory, std::string_view directory, std::span<const ConfiguredPlugin> configured, const Environment &environment) -> TapConfiguration<Memory>;

}
