// The agents and tasks the user follows: the order their cards take, what a project, a tab and a
// task card say of them, the mark of each agent's application, and the cards' geometry and pulse.
// Each window orders and draws the cards of its machines every frame, so the feature has no state
// of the session's; its use cases find the agent or pane the user chose among what the runtime
// reports.
export module telar.gui.features.activity;

export import :labels;
export import :mark;
export import :order;
export import :presentation;

import std;

import telar.base.memory.allocators;
import telar.gui.foundation.model;
import telar.base.ds;
import telar.tbc;

export namespace telar::gui::features::activity {

  // The agent the runtime reports in pane `pane_id`, at `generation` when one is given: the one a
  // card the user chose shows, if it still does.
  [[nodiscard]] tbc::val_a<const Agent<Memory>*> find(tbc::val_a<std::span<const Agent<Memory>>> agents, std::uint64_t pane_id, ds::Option<std::uint64_t> generation = ds::none) noexcept;

  // The agent in the pane `tab` focuses, if one runs there.
  [[nodiscard]] tbc::val_a<const Agent<Memory>*> focused(tbc::val_a<std::span<const Agent<Memory>>> agents, const Tab<Memory>& tab) noexcept;

  // The workspace the pane the user chose lives in, by what the runtime reports of it as an agent
  // or else lists of it: where to go when the pane is gone. None when neither knows it at
  // `generation`, or it lives in no workspace.
  [[nodiscard]] ds::Option<std::uint64_t> workspaceOf(std::span<const Agent<Memory>> agents, std::span<const ListedPane> listed, std::uint64_t pane_id, ds::Option<std::uint64_t> generation) noexcept;

}
