module;
#include "telar_wire/protocol/pane_io.hpp"

export module telar.wire.pane_io;

// Pane lifecycle and I/O: opening and closing panes, input, resizing, frames and
// the state a pane reports.
//
// The owned textual header stays in this global module fragment only; importers reach
// its names through these declarations.
//
// The vocabulary declares `PaneForeground` and `PaneFrame`. This module carries their
// schemas and exports the names too, so the units that send or decode them import
// this module.

// The schemas are specializations of `MessageSchema` in the global fragment. A reduced BMI
// drops the fragment declarations a module never names, so naming the template here keeps
// them reachable from importers.
export namespace telar {
  using telar::MessageSchema;
}

export namespace telar {
  using telar::ClosePane;
  using telar::ConfigureFrameInterval;
  using telar::ConfigurePaneDesktop;
  using telar::ConfigureShellPrompt;
  using telar::ConfigureTerminalColors;
  using telar::CreatePane;
  using telar::DetachPane;
  using telar::FrameAck;
  using telar::max_pane_list_entries;
  using telar::OpenPane;
  using telar::PaneCommand;
  using telar::PaneCwd;
  using telar::PaneExited;
  using telar::PaneForeground;
  using telar::PaneFrame;
  using telar::PaneGit;
  using telar::PaneInput;
  using telar::PaneList;
  using telar::PaneOpened;
  using telar::PaneProgress;
  using telar::PaneResize;
  using telar::PaneShell;
  using telar::PaneTitle;
  using telar::RequestSnapshot;
  using telar::SendPaneText;
  using telar::SetPaneViewport;
  using telar::VerifyPaneDescent;
}
