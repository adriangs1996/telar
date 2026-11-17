// The path picker as ui drives it: open it from the focused pane, search, browse and insert the
// chosen path.
export module telar.gui.application:paths;

import std;

import :session;
import telar.gui.features.paths;
import telar.wire.editor;
import telar.wire.runtime;

export namespace telar::gui::application::paths {

  using features::paths::PathInsertion;
  using features::paths::PathLabel;
  using features::paths::PathLabelRun;
  using features::paths::PathLabelTone;
  using features::paths::PathPickerFieldColumns;
  using features::paths::PathPickerFooter;
  using features::paths::PathPickerGeometry;
  using features::paths::PathPickerHint;
  using features::paths::PathPickerHintPlacement;
  using features::paths::PathPickerLabels;
  using features::paths::PathPickerLimits;
  using features::paths::PathPickerMatch;
  using features::paths::PathPickerPage;
  using features::paths::PathPickerPhase;
  using features::paths::PathPickerPlacement;
  using features::paths::PathPickerRowPlacement;

  // Opens the picker at the focused pane's directory and searches from the word before the
  // line's caret; false when no attached pane with a known directory has the focus.
  bool open(Session& session);

  // The word the search started from, which the chosen path replaces.
  [[nodiscard]] std::string_view seed(const Session& session) noexcept;

  // Searches the picker's root for `query`; false while it is closed or the queue is full.
  bool search(Session& session, std::string_view query);

  // Browses into the selected directory and searches it from nothing.
  bool descend(Session& session, std::size_t selection);

  // Browses to the root's parent and searches it from nothing.
  bool ascend(Session& session);

  void close(Session& session) noexcept;

  // Inserts the selected match, relative to the directory the picker opened at or `absolute`,
  // at the focused pane's editor or shell, and closes the picker.
  bool insert(Session& session, std::size_t selection, bool absolute);

  [[nodiscard]] PathPickerPage page(const Session& session) noexcept;

}

// What the session's routing hands the path picker; ui never calls these.
namespace telar::gui::application::paths {

  Change receive(Session& session, const PathResults& results);

  // A failed request: none when it is not one of the picker's.
  std::optional<Change> fail(Session& session, const RequestFailed& failure);

}
