#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "machine_client_key.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <cstdint>
#include <variant>

#pragma once



import telar.gui.palette.navigation_label;

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

  // A pane no agent holds, listed by the process in its foreground.
  struct Process {
    std::uint64_t pane_id;
    std::uint64_t pane_generation;
  };

  MachineClientKey source;
  std::uint64_t runtime_generation;
  std::variant<Agent, Command, Process> owner;
};

}
