// The path picker: a search of the pane's directory tree from the line's prompt, browsing into
// and out of directories, and the path chosen inserted at the shell or the editor.
export module telar.gui.features.paths;

export import :page;
export import :presentation;
// Exported as every interface partition must be; it exports nothing.
export import :picker;

import std;

import telar.base.memory.containers;
import telar.wire.editor;
import telar.wire.runtime;

namespace telar::gui::features::paths {

  struct Access;

}

export namespace telar::gui::features::paths {

  // The relative word before the line's caret the search started from, which the chosen path
  // replaces; empty when the search started from nothing.
  struct PathSeed {
    std::uint64_t pane_id = 0;
    std::size_t begin = 0;
    std::string_view text;
  };

  // The picker's search and page, and the word it started from. Opaque: only the use cases below
  // reach it.
  class State {
    friend struct Access;

    struct Seed {
      std::uint64_t pane_id = 0;
      std::size_t begin = 0;
      runtime::FixedText<PathPickerLimits::query_bytes> text;
    };

    PathPicker picker_;
    Seed seed_;
  };

  [[nodiscard]] PathPickerPage page(const State& state) noexcept;

  [[nodiscard]] PathSeed seed(const State& state) noexcept;

  // Opens the picker for pane `pane_id` at `directory`. `word` is the word before the line's
  // caret; the search starts from it when it is a plain relative path, as `src/ma` is.
  void open(State& state, std::uint64_t pane_id, std::string_view directory, PathSeed word);

  // The search for `query` under the picker's root, under `request_id`, while the picker is open
  // (page(state).paneId() is not 0).
  [[nodiscard]] FindPaths search(const State& state, std::string_view query, std::uint64_t request_id) noexcept;

  // The search `request_id` went out: its answer is the one awaited.
  void wait(State& state, std::uint64_t request_id) noexcept;

  // Shows `message` in place of the matches: what kept a search or an insertion from happening.
  void report(State& state, std::string_view message);

  // Browses into the selected match when it is a directory; false otherwise.
  bool descend(State& state, std::size_t selection);

  // Browses to the parent of the root; false at the filesystem's root.
  bool ascend(State& state);

  void close(State& state) noexcept;

  // Pane `pane_id` is gone: a word taken from its line is forgotten.
  void forget(State& state, std::uint64_t pane_id) noexcept;

  // Whether a match can be inserted; when not, the picker says why.
  bool insertable(State& state);

  // The text that inserts the chosen match, quoted for the shell; none when it does not fit.
  [[nodiscard]] std::optional<PathInsertion::Text> insertion(const State& state, PathInsertion::Choice choice);

  // A page of matches: false when it is not the awaited search's.
  bool receive(State& state, const PathResults& results);

  // A failed request: none when it is not one of the picker's, otherwise whether what the picker
  // shows changed.
  [[nodiscard]] std::optional<bool> fail(State& state, const RequestFailed& failure);

}

namespace telar::gui::features::paths {

  // The use cases' way into State.
  struct Access {
    [[nodiscard]] static constexpr PathPicker& picker(State& state) noexcept {
      return state.picker_;
    }

    [[nodiscard]] static constexpr const PathPicker& picker(const State& state) noexcept {
      return state.picker_;
    }

    [[nodiscard]] static constexpr State::Seed& seed(State& state) noexcept {
      return state.seed_;
    }

    [[nodiscard]] static constexpr const State::Seed& seed(const State& state) noexcept {
      return state.seed_;
    }
  };

}
