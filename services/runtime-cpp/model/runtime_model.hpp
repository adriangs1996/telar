#pragma once

#include "../diagnostics/runtime_counters.hpp"
#include "client.hpp"
#include "exited_panes.hpp"
#include "pane.hpp"
#include "runtime_limits.hpp"
#include "slot_store.hpp"
#include "telar_config/agents/builtin_manifests.hpp"
#include "workspace.hpp"
#include "worktrees.hpp"

namespace telar::runtime {

template <Allocator Memory>
struct RuntimeModel {
  explicit RuntimeModel(Memory &memory, GraphicsLimits graphics = {})
      : graphics_limits(graphics),
        media_budget(graphics.global_bytes),
        panes(memory),
        clients(memory),
        workspaces(memory),
        worktrees(memory) {}

  std::uint32_t clientBit(std::uint64_t identity) const noexcept {
    const auto slot = clients.slotOf(identity);
    return slot ? std::uint32_t{1} << *slot : 0;
  }

  bool tabHeld(TabLocation location) const noexcept {
    for (const auto *client : clients.items()) {
      if (client != nullptr && !client->connection.closing && client->held_tabs.contains(location)) {
        return true;
      }
    }

    return false;
  }

  GraphicsLimits graphics_limits;
  RuntimeLimits limits;
  [[no_unique_address]] diagnostics::RuntimeCounters metrics;
  MediaBudget media_budget;
  AgentManifests manifests = builtin_manifests;
  std::string_view cli_executable;
  bool capture_output = false;
  SlotStore<Pane<Memory>, 256, Memory> panes;
  SlotStore<ClientSession<Memory>, 32, Memory> clients;
  SlotStore<Workspace<Memory>, 64, Memory> workspaces;
  Worktrees<Memory> worktrees;
  ExitedPanes exited_panes;
  std::shared_ptr<PaneObserver<Memory>> retired_observers;
  std::size_t retired_observer_count = 0;
  std::shared_ptr<PaneMedia<Memory>> retired_media;
  std::size_t retired_media_count = 0;
  std::uint64_t next_tab_id = 1;
  std::uint64_t workspace_revision = 1;
  std::uint64_t next_pane_generation = 1;
  std::uint64_t input_sequence = 0;
  bool stopping = false;
};

}
