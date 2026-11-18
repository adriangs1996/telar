// The peek at an agent from its activity card: its recent screen and facts beside the current
// tab, and a message, /open, /stop or /diff for it.
export module telar.gui.features.peek;

export import :target;
export import :presentation;
// Exported as every interface partition must be; it exports nothing.
export import :screen;

import std;

import telar.base.memory.allocators;
import telar.gui.foundation.model;
import telar.wire.content;
import telar.base.ds;

namespace telar::gui::features::peek {

  struct Access;

}

export namespace telar::gui::features::peek {

  // The open peek, if any, its agent's screen as last read and the read in flight. Opaque: only
  // the use cases below reach it.
  class State {
    friend struct Access;

  public:
    explicit State(Memory& memory);

  private:
    PeekScreen<Memory> screen_;
  };

  // What the field asked for once submitted: a message, trimmed, or one of the slash words.
  struct Submission {
    PeekCommand command = PeekCommand::message;
    std::string_view message;
  };

  [[nodiscard]] const ds::Option<PeekTarget>& target(const State& state) noexcept;

  [[nodiscard]] std::string_view text(const State& state) noexcept;

  // Whether a read of the agent's screen is in flight.
  [[nodiscard]] bool reading(const State& state) noexcept;

  // The agent `target` names among `agents`, while that agent's session lives.
  [[nodiscard]] const Agent<Memory>* find(std::span<const Agent<Memory>> agents, const PeekTarget& target) noexcept;

  // The peeked agent among `agents`; none once it is gone or nothing is open.
  [[nodiscard]] const Agent<Memory>* agent(const State& state, std::span<const Agent<Memory>> agents) noexcept;

  // Opens a peek at `target`, forgetting what the last one read.
  void open(State& state, PeekTarget target) noexcept;

  void close(State& state) noexcept;

  // The read of the agent's recent rows under `request_id`; none while one is in flight or no
  // peek is open.
  [[nodiscard]] ds::Option<ReadPane> read(State& state, std::uint64_t request_id);

  // The read `request_id` failed: false when it is not the one in flight.
  bool fail(State& state, std::uint64_t request_id) noexcept;

  // The agent's screen arrived: the bytes dropped from its head to fit PeekLimits::text_bytes,
  // or none when the reply is not the open peek's.
  [[nodiscard]] ds::Option<std::size_t> receive(State& state, const PaneText& reply);

  // What submitting `text` asks for. Throws std::length_error past PeekLimits::message_bytes.
  [[nodiscard]] Submission submit(std::string_view text);

}

namespace telar::gui::features::peek {

  // The use cases' way into State.
  struct Access {
    [[nodiscard]] static constexpr PeekScreen<Memory>& screen(State& state) noexcept {
      return state.screen_;
    }

    [[nodiscard]] static constexpr const PeekScreen<Memory>& screen(const State& state) noexcept {
      return state.screen_;
    }
  };

}
