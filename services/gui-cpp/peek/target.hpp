#pragma once

#include "palette/navigation_target.hpp"
#include "telar_client/serializers/telar_messages.hpp"

namespace telar::gui {

struct PeekTarget {
  AgentNavigationTarget agent;
  decltype(AgentSnapshotEntry::session_id) session{};

  bool operator==(const PeekTarget &) const noexcept = default;
};

}
