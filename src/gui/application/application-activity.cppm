// The agents and tasks as ui drives them: the types each window orders and draws its cards with,
// and the agent or pane the user chooses, which the session shows wherever it lives.
export module telar.gui.application:activity;

import std;

import :session;
import telar.gui.features.activity;
import telar.wire.agents;

export namespace telar::gui::application::activity {

  using features::activity::ActivityOrder;
  using features::activity::AgentAnimation;
  using features::activity::AgentCardGeometry;
  using features::activity::AgentOrder;
  using features::activity::ApplicationMark;
  using features::activity::ProjectActivity;
  using features::activity::TabActivity;
  using features::activity::TaskCardLabels;

  // The user chose the card of the agent in pane `pane_id`: the session shows that pane, in this
  // workspace or by opening the one it lives in. False when the runtime no longer reports that
  // agent at `generation`.
  bool chooseAgent(Session& session, std::uint64_t pane_id, std::uint64_t generation);

  // The user chose pane `pane_id` from the runtime's list of panes, as chooseAgent does.
  bool choosePane(Session& session, std::uint64_t pane_id, std::uint64_t generation);

}

// What the session's routing and the other use cases hand the agents; ui never calls these.
namespace telar::gui::application::activity {

  // Tells the runtime the user saw the agent in the focused pane, once per status it shows.
  void acknowledge(Session& session);

  Change receive(Session& session, const AgentSnapshot& message);

  Change receive(Session& session, const PaneList& message);

  Change receive(Session& session, const PaneFacts& message);

}
