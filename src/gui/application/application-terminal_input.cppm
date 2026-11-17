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

}
