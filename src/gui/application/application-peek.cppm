// The peek at an agent as ui drives it: open it from an activity card, read what it shows,
// submit its field.
export module telar.gui.application:peek;

import std;

import :session;
import telar.base.memory.allocators;
import telar.gui.features.peek;
import telar.gui.foundation.model;
import telar.wire.content;

export namespace telar::gui::application::peek {

  using features::peek::PeekGeometry;
  using features::peek::PeekLabels;
  using features::peek::PeekLimits;
  using features::peek::PeekTarget;

  // Peeks at `target`'s agent and asks for its recent screen; false while the session is hidden
  // or not ready, or once the agent is gone.
  bool open(Session& session, PeekTarget target);

  void close(Session& session) noexcept;

  // Sends the field to the peeked agent, or does what its slash word asks, and closes the peek;
  // false, with the peek closed, once the agent is gone.
  bool submit(Session& session, std::string_view text);

  [[nodiscard]] const std::optional<PeekTarget>& target(const Session& session) noexcept;

  // The peeked agent, while it lives.
  [[nodiscard]] const Agent<Memory>* agent(const Session& session) noexcept;

  // The agent's screen as last read.
  [[nodiscard]] std::string_view text(const Session& session) noexcept;

  // Its last `rows` lines, what the peek's screen shows.
  [[nodiscard]] std::string_view lines(const Session& session, std::uint16_t rows) noexcept;

  // Whether a read of the agent's screen is in flight.
  [[nodiscard]] bool reading(const Session& session) noexcept;

}

// What the session's routing hands the peek; ui never calls these.
namespace telar::gui::application::peek {

  // The agents changed: the peek closes once its agent is gone, and reads its screen again.
  void follow(Session& session);

  Change receive(Session& session, const PaneText& reply);

  // The runtime refused the screen read `request_id`: the peek stays, ready to read again.
  void readFailed(Session& session, std::uint64_t request_id) noexcept;

  // The runtime refused what a submit sent to the agent of pane `pane_id`.
  Change actionFailed(Session& session, std::uint64_t pane_id, std::string_view message);

}
