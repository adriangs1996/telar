module;
#include "telar_client/protocol/layout.hpp"

export module telar.wire.layout;

// Workspaces, tabs, the client layout and pane focus.
//
// The owned textual header stays in this global module fragment only; importers reach
// its names through these declarations.

// The schemas are specializations of `MessageSchema` in the global fragment. A reduced BMI
// drops the fragment declarations a module never names, so naming the template here keeps
// them reachable from importers.
export namespace telar {
  using telar::MessageSchema;
}

export namespace telar {
  using telar::ClientLayoutSnapshot;
  using telar::CloseTab;
  using telar::CompletePaneFocus;
  using telar::CreateTab;
  using telar::CreateWorkspace;
  using telar::HoldTab;
  using telar::LaunchTab;
  using telar::MoveTab;
  using telar::PaneFocusCommand;
  using telar::PaneFocusResult;
  using telar::RenameTab;
  using telar::RenameWorkspace;
  using telar::RequestPaneFocus;
  using telar::RequestTabSnapshot;
  using telar::RequestWorkspaceSnapshot;
  using telar::ResyncRequired;
  using telar::TabClosed;
  using telar::TabCreated;
  using telar::TabMoved;
  using telar::TabRenamed;
  using telar::TabSnapshot;
  using telar::UpdateClientLayout;
  using telar::WorkspaceList;
  using telar::WorkspaceSnapshot;
}
