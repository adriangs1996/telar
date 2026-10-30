#pragma once

#include "workspace_notifications.hpp"

namespace telar::runtime {

template <Allocator Memory>
bool acquireGeometry(RuntimeModel<Memory> &model, const ClientSession<Memory> &client, Workspace<Memory> &workspace) {
  if (workspace.geometry_client) {
    TELAR_DIAGNOSTIC(if (*workspace.geometry_client != client.id) { diagnostics::accumulate(model.metrics.geometry_rejections); });
    return *workspace.geometry_client == client.id;
  }

  workspace.geometry_client = client.id;
  for (auto *pane : model.panes.items()) {
    if (pane != nullptr && pane->location.workspace.id == workspace.id) {
      if (!pane->desktop_theme) {
        pane->terminal.configureColors(client.colors);
        pane->terminal.resumeControl();
      }
    }
  }

  return true;
}

template <Allocator Memory>
void releaseGeometry(RuntimeModel<Memory> &model, std::uint64_t client, Workspace<Memory> &workspace) noexcept {
  if (workspace.geometry_client == client) {
    workspace.geometry_client.reset();
    notifyWorkspaceObservers(model, workspace.id, client);
  }
}

template <Allocator Memory>
void releaseAllGeometry(RuntimeModel<Memory> &model, std::uint64_t client) noexcept {
  for (auto *workspace : model.workspaces.items()) {
    if (workspace != nullptr) {
      releaseGeometry(model, client, *workspace);
    }
  }
}

}
