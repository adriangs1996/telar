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

  void PaneFacts::validate() const {
    if ((command_state == PaneCommandState::none) != command.empty()) {
      throw EncodingError{"A pane's command and its state disagree"};
    }

    if (command_state != PaneCommandState::finished && (exit_code || duration_ms != 0)) {
      throw EncodingError{"Only a finished command has an exit code and a duration"};
    }

    if (command.empty() && command_truncated) {
      throw EncodingError{"An empty command cannot be truncated"};
    }

    if (dirty && branch.empty()) {
      throw EncodingError{"Changes without a repository"};
    }
  }

}
}
