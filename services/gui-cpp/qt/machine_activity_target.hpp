#pragma once

#include "machine_client_key.hpp"
#include "palette/navigation_target.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <cstdint>
#include <variant>

namespace telar::gui::qt {

struct MachineActivityTarget {
  struct Agent {
    AgentNavigationTarget key;
    decltype(AgentSnapshotEntry::session_id) session;
  };

  struct Command {
    std::uint64_t worktree;
    std::uint64_t workspace;
  };

  MachineClientKey source;
  std::uint64_t runtime_generation;
  std::variant<Agent, Command> owner;
};

}
