// A command suggested for a task the user described: where its request stands and what
// submitting the suggest field does.
export module telar.gui.features.palette:suggestion;

import std;

import telar.wire.vocabulary;

export namespace telar::gui::features::palette {

  enum class SuggestionPhase : std::uint8_t {
    idle,
    waiting,
    ready,
    failed,
  };

  // The suggestion as the palette shows it. `text` lives in the state it was read from.
  struct Suggestion {
    SuggestionPhase phase = SuggestionPhase::idle;
    SuggestionStatus status = SuggestionStatus::ready;
    std::string_view text;
    std::uint64_t revision = 0;
    std::uint64_t pending_request = 0;
  };

  // What submitting the suggest field does: type the suggestion that landed, ask the runtime
  // for one for the task, or nothing while one is awaited or the task is empty.
  struct Submission {
    enum class Kind : std::uint8_t {
      none,
      insert,
      ask,
    };

    Kind kind = Kind::none;
    std::string_view text;
  };

}
