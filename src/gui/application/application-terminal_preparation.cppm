export module telar.gui.application:terminal_preparation;

import std;
import telar.gui.foundation.core;
import telar.gui.presentation.frame_pacer;
import telar.gui.features.terminal.links;

// Interface: presentation/terminal_preparation.cppm
export {
  namespace telar::gui::application {

    struct TerminalPreparation {
      FramePacer::Pane pane;
      std::optional<features::terminal::links::PresentedLink> links;
      std::uint64_t revision = 0;
    };

  }
}
