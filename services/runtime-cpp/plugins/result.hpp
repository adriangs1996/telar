#pragma once

#include "effects.hpp"
#include "service_spec.hpp"
#include "telar_base/memory/sensitive_allocation.hpp"

namespace telar::runtime::plugins {

template <Allocator Memory>
struct Result {
  explicit Result(const ServiceSpec &specification, SensitiveAllocation<Memory> storage, EffectReply reply, bool traffic = false) noexcept
      : package_index(specification.package_index), plugin_id(specification.plugin_id), digest(specification.digest), generation(specification.generation), event_id(reply.event_id), storage(std::move(storage)), batch(reply.batch), traffic(traffic) {}

  bool authorized(const ServiceSpec &specification) const noexcept {
    const bool source = traffic ? specification.traffic() : specification.allows(Capability::proxy_tap);
    return package_index == specification.package_index && plugin_id == specification.plugin_id && digest == specification.digest && generation == specification.generation && source && (batch.count == 0 || specification.allows(Capability::notifications));
  }

  std::uint8_t package_index;
  std::uint64_t plugin_id;
  PackageDigest digest;
  std::uint64_t generation;
  std::uint64_t event_id;
  SensitiveAllocation<Memory> storage;
  EffectBatch batch;
  bool traffic = false;
};

template <Allocator Memory>
using OwnedResult = Owned<Result<Memory>, Memory>;

}
