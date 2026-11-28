module telar.gui.ui.kit.models;

import std;
import telar.gui.ui.kit.store;
import telar.gui.application;

namespace telar::gui::qt {

  bool activityAvailable(const Store& store, const application::machines::MachineActivityTarget& target) {
    const auto* client = store.find(target.source);
    const auto slot = target.source.machine.slot;
    if (client == nullptr || client->runtime_generation != target.runtime_generation || !store.machines().shown(slot) || !store.machines().row(slot).live || !store.machines().row(slot).enabled || client->phase != application::machines::MachinePhase::connected || !client->session.ready()) {
      return false;
    }

    if (const auto* agent = std::get_if<application::machines::MachineActivityTarget::Agent>(&target.owner)) {
      return std::ranges::any_of(client->session.agents(), [&](const auto& candidate) {
        return candidate.pane_id == agent->key.pane_id && candidate.pane_generation == agent->key.pane_generation && candidate.session_id == agent->session;
      });
    }

    if (const auto* process = std::get_if<application::machines::MachineActivityTarget::Process>(&target.owner)) {
      return std::ranges::any_of(client->session.paneList(), [&](const auto& pane) {
        return pane.pane_id == process->pane_id && pane.pane_generation == process->pane_generation;
      });
    }

    const auto command = std::get<application::machines::MachineActivityTarget::Command>(target.owner);
    const auto* row = client->session.workspace_list.worktree(command.worktree);

    return row != nullptr && row->workspace && *row->workspace == command.workspace;
  }

}
