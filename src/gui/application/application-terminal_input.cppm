// The terminal's input from the pointer as ui drives it: the types a terminal's gestures and
// encoders hold, and the wheel scrolling the focused pane from a binding.
export module telar.gui.application:terminal_input;

import :session;
import :workspace_replica;
import telar.gui.features.terminal.input;

export namespace telar::gui::application::terminal::input {

  using features::terminal::input::ChildMouseGesture;
  using features::terminal::input::ChildMouseProjection;
  using features::terminal::input::ChildMouseReport;
  using features::terminal::input::ChildMouseSample;
  using features::terminal::input::ChildMouseView;
  using features::terminal::input::MouseButton;
  using features::terminal::input::MouseEncoder;
  using features::terminal::input::MousePhase;

  // A wheel step on the focused pane: reported to a program that tracks the mouse, arrow keys
  // to one on the alternate screen, the view scrolled otherwise.
  void scroll(Session& session, ScrollDirection direction);

  // The row a pane's terminal draws at its top, which the session then scrolls from: the terminal
  // glides between the runtime's views, so where it draws is not always where the runtime is.
  // Nothing while it draws the runtime's own view.
  void showTop(Session& session, std::uint64_t pane_id, ds::Option<std::uint64_t> top) noexcept;

  // Gives back the rows a pane keeps beyond its screen once nothing folds them out of it; its
  // terminal asks when its view has come to rest.
  void releaseRows(Session& session, std::uint64_t pane_id);

}
