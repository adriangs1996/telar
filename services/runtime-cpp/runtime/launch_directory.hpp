#pragma once

#include "../model/runtime_model.hpp"
#include "request_error.hpp"
#include <variant>

namespace telar::runtime {

using LaunchDirectoryScope = std::variant<std::monostate, WorkspaceLocation, TabLocation>;

template <Allocator Memory>
Launch resolveLaunchDirectory(const RuntimeModel<Memory> &model, const ClientSession<Memory> &client, Launch launch, LaunchDirectoryScope scope = {}) {
  if (launch.cwd_source == 0) {
    return launch;
  }

  const auto *pane = model.panes.find(launch.cwd_source);
  if (client.attachment(launch.cwd_source) == nullptr || pane == nullptr || pane->close_requested || pane->exit_status) {
    throw RequestError{FailureCode::invalid_request, "cwd source pane is unavailable"};
  }

  const auto *workspace = std::get_if<WorkspaceLocation>(&scope);
  const auto *tab = std::get_if<TabLocation>(&scope);
  if (tab != nullptr) {
    workspace = &tab->workspace;
  }
  if (workspace != nullptr && (workspace->kind != pane->location.workspace.kind || workspace->id != pane->location.workspace.id)) {
    throw RequestError{FailureCode::invalid_request, "cwd source pane is unavailable"};
  }
  if (tab != nullptr && tab->tab_id != pane->location.tab_id) {
    throw RequestError{FailureCode::invalid_request, "cwd source pane is unavailable"};
  }

  launch.cwd = pane->cwd;
  launch.cwd_source = 0;
  return launch;
}

}
