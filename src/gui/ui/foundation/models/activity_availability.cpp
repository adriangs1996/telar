#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/foundation/machines/machine_client.hpp"
#include "ui/foundation/store/store.hpp"
#include <algorithm>
#include <variant>

import telar.gui.machines.picker;

namespace telar::gui::qt {

  bool activityAvailable(const Store& store, const MachineActivityTarget& target) {
    const auto* client = store.find(target.source);
    const auto slot = target.source.machine.slot;
    if (client == nullptr || client->runtime_generation != target.runtime_generation || !store.machines().shown(slot) || !store.machines().row(slot).live || !store.machines().row(slot).enabled || client->phase != MachinePhase::connected || !client->session.ready()) {
      return false;
    }

    if (const auto* agent = std::get_if<MachineActivityTarget::Agent>(&target.owner)) {
      return std::ranges::any_of(client->session.agents(), [&](const auto& candidate) {
        return candidate.pane_id == agent->key.pane_id && candidate.pane_generation == agent->key.pane_generation && candidate.session_id == agent->session;
      });
    }

    if (const auto* process = std::get_if<MachineActivityTarget::Process>(&target.owner)) {
      return std::ranges::any_of(client->session.paneList(), [&](const auto& pane) {
        return pane.pane_id == process->pane_id && pane.pane_generation == process->pane_generation;
      });
    }

    const auto command = std::get<MachineActivityTarget::Command>(target.owner);
    const auto* row = client->session.workspaceList().worktree(command.worktree);

    return row != nullptr && row->workspace && *row->workspace == command.workspace;
  }

}
