// The palette as ui drives it: the field's modes and rows, and the command suggested for a
// task.
export module telar.gui.application:palette;

import std;

import :session;
import telar.gui.features.palette;
import telar.wire.editor;

export namespace telar::gui::application::palette {

  using features::palette::NavigationLabel;
  using features::palette::palette_actions;
  using features::palette::PaletteAction;
  using features::palette::PaletteGeometry;
  using features::palette::PaletteMode;
  using features::palette::PaletteQuery;
  using features::palette::PaletteRowKind;
  using features::palette::PaletteRowWindow;
  using features::palette::Suggestion;
  using features::palette::SuggestionGeometry;
  using features::palette::SuggestionLabels;
  using features::palette::SuggestionPhase;

  [[nodiscard]] Suggestion suggestion(const Session& session) noexcept;

  // The suggest mode opened: an empty suggestion, forgetting a request in flight.
  void suggest(Session& session) noexcept;

  // The task changed or the machine did: what was asked or shown is dropped.
  void discard(Session& session) noexcept;

  // Submits the suggest field: types a suggestion that landed into the focused pane, true when
  // it did, or asks the runtime for one for `task`.
  bool submit(Session& session, std::string_view task);

}

// What the session's routing hands the palette; ui never calls it.
namespace telar::gui::application::palette {

  Change receive(Session& session, const CommandSuggestion& suggestion);

}
