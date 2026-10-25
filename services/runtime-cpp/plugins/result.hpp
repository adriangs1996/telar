#pragma once

#include "../memory/sensitive_allocation.hpp"
#include "effects.hpp"
#include "service_spec.hpp"

namespace telar::runtime::plugins {

template <Allocator Memory>
struct Result {
  explicit Result(const ServiceSpec &specification, SensitiveAllocation<Memory> storage, EffectReply reply) noexcept
      : package_index(specification.package_index), plugin_id(specification.plugin_id), digest(specification.digest), generation(specification.generation), event_id(reply.event_id), storage(std::move(storage)), batch(reply.batch) {}

  bool authorized(const ServiceSpec &specification) const noexcept {
    return package_index == specification.package_index && plugin_id == specification.plugin_id && digest == specification.digest && generation == specification.generation && specification.allows(Capability::proxy_tap) && (batch.count == 0 || specification.allows(Capability::notifications));
  }

  std::uint8_t package_index;
  std::uint64_t plugin_id;
  PackageDigest digest;
  std::uint64_t generation;
  std::uint64_t event_id;
  SensitiveAllocation<Memory> storage;
  EffectBatch batch;
};

template <Allocator Memory>
using OwnedResult = Owned<Result<Memory>, Memory>;

}
