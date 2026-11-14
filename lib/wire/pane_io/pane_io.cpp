module telar.wire.pane_io;

import std;
import telar.wire.vocabulary;

// The owned header declares these in the global module, so their definitions belong to it too.
extern "C++" {
namespace telar {

  void SendPaneText::validate() const {
    if (text.empty() && mode != PaneTextMode::raw_enter) {
      throw EncodingError{"Empty pane text"};
    }
  }

  void ConfigurePaneDesktop::validate() const {
    if (focused && !visible) {
      throw EncodingError{"A focused pane must be visible"};
    }
  }

  void PaneProgress::validate() const {
    if ((state == PaneProgressState::remove || state == PaneProgressState::indeterminate) &&
        percent) {
      throw EncodingError{"Unexpected progress percent"};
    }

    if (state == PaneProgressState::set && !percent) {
      throw EncodingError{"Missing progress percent"};
    }
  }

  void PaneShell::validate() const {
    if (shell == IntegratedShell::none && phase != ShellPhase::unknown) {
      throw EncodingError{"Shell phase without an integrated shell"};
    }
  }

}
}
