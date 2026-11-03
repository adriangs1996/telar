#pragma once

#include "../platform/process_lineage.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_platform/observation_time.hpp"
#include <bit>

namespace telar::runtime {

struct ReporterIdentity {
  std::uint64_t pane = 0;
  std::uint64_t generation = 0;
  AgentProvider provider = AgentProvider::unknown;
};

struct RejectedReporter {
  pid_t group = 0;
  pid_t agent = 0;
  pid_t process = 0;
  bool operator==(const RejectedReporter &) const = default;
};

template <Allocator Memory>
struct DeferredReport {
  explicit DeferredReport(Memory &memory)
      : payload(AllocatorRef<Byte, Memory>{memory}) {}

  bool rechecked(std::uint32_t completed) const noexcept {
    return std::bit_cast<std::int32_t>(completed - required_recheck) >= 0;
  }

  ObservationTime reportTime() const noexcept {
    return answering ? observed : ObservationTime::now();
  }

  Vector<Byte, Memory> payload;
  ReporterIdentity reporter;
  ObservationTime observed;
  std::uint64_t sequence = 0;
  std::uint32_t required_recheck = 0;
  bool pending = false;
  bool answering = false;
  bool answer_rechecked = false;
};

}
