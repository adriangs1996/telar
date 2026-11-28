export module telar.gui.ui.kit.models:activity_availability;

import telar.gui.application;
import telar.gui.ui.kit.store;

export namespace telar::gui::qt {

  // Whether the target is still there to select: its machine connected and shown, and its
  // agent, process or worktree still listed.
  [[nodiscard]] bool activityAvailable(const Store& store, const application::machines::MachineActivityTarget& target);

}
