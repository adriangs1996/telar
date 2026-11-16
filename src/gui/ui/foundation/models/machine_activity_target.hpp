#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_client/serializers/telar_messages.hpp"
#include "ui/foundation/machines/machine_client_key.hpp"
#include <cstdint>
#include <variant>

#pragma once

import telar.gui.palette.navigation_label;

namespace telar::gui::qt {

  class Store;

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

  // Whether the target is still there to select: its machine connected and shown, and its
  // agent, process or worktree still listed.
  [[nodiscard]] bool activityAvailable(const Store& store, const MachineActivityTarget& target);

}
