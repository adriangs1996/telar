// The palette: one field that navigates to a context, tab or agent, runs an action, switches
// machine, or describes a task to get a command suggested for it.
export module telar.gui.features.palette;

export import :query;
export import :suggestion;
export import :presentation;
// Exported as every interface partition must be; it exports nothing.
export import :suggestion_state;

import std;

import telar.wire.editor;

namespace telar::gui::features::palette {

  struct Access;

}

export namespace telar::gui::features::palette {

  // The suggestion the suggest mode asks for and shows. Opaque: only the use cases below reach
  // it.
  class State {
    friend struct Access;

    SuggestionState suggestion_;
  };

  [[nodiscard]] Suggestion suggestion(const State& state) noexcept;

  // The suggest mode opened: an empty suggestion, forgetting a request in flight.
  void suggest(State& state) noexcept;

  // The task changed, or the suggestion lost its pane: what was asked or shown is dropped.
  void discard(State& state) noexcept;

  // What submitting `task` does.
  [[nodiscard]] Submission submit(const State& state, std::string_view task) noexcept;

  // The runtime was asked under `request_id`; its answer is the one awaited.
  void wait(State& state, std::uint64_t request_id) noexcept;

  // Nothing could be asked: the suggestion fails as if the runtime refused it.
  void fail(State& state) noexcept;

  // The runtime's answer: false when it is not the one awaited. Throws EncodingError past
  // SuggestionLimits::text_bytes.
  bool receive(State& state, const CommandSuggestion& suggestion);

}

namespace telar::gui::features::palette {

  // The use cases' way into State.
  struct Access {
    [[nodiscard]] static constexpr SuggestionState& suggestion(State& state) noexcept {
      return state.suggestion_;
    }

    [[nodiscard]] static constexpr const SuggestionState& suggestion(const State& state) noexcept {
      return state.suggestion_;
    }
  };

}
