#pragma once

#include "telar_client/serializers/telar_messages.hpp"
#include <cstdint>
#include <variant>

namespace telar::gui {

struct AgentNavigationTarget {
  std::uint64_t pane_id = 0;
  std::uint64_t pane_generation = 0;

  bool operator==(const AgentNavigationTarget &) const = default;
};

using NavigationTarget = std::variant<WorkspaceLocation, TabLocation, AgentNavigationTarget>;

}
