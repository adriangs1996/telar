#pragma once

#include "telar_client/serializers/telar_messages.hpp"
#include <cstdint>

namespace telar::gui {

struct AgentStatusChange {
  std::uint64_t pane_id = 0;
  std::uint64_t pane_generation = 0;
  std::uint16_t pane_index = 0;
  AgentProvider provider = AgentProvider::unknown;
  AgentStatus previous = AgentStatus::unknown;
  AgentStatus current = AgentStatus::unknown;
};

}
