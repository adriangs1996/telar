#pragma once

#include "app_state.hpp"
#include <algorithm>
#include <optional>

struct RuntimeWorkspace {
  std::uint64_t id = 0;
  bool worktree = false;

  bool operator==(const RuntimeWorkspace &) const = default;
  auto operator<=>(const RuntimeWorkspace &) const = default;
};

struct RuntimeTab {
  std::uint64_t id = 0;
  std::string label;
  std::vector<std::string> foregrounds;

  bool operator==(const RuntimeTab &) const = default;
};

// A workspace on screen, with the tabs its latest snapshot reported.
struct RuntimeView {
  RuntimeWorkspace workspace;
  std::string name;
  std::uint64_t active_tab = 0;
  std::vector<RuntimeTab> tabs;

  bool operator==(const RuntimeView &) const = default;
};

// The outcome of the latest workspace creation; `workspace` is 0 when it failed.
struct WorkspaceCreation {
  std::uint64_t request = 0;
  std::uint64_t workspace = 0;

  bool operator==(const WorkspaceCreation &) const = default;
};

struct RuntimeState {
  bool connected = false;
  bool workspaces_ready = false;
  // The workspace input goes to: the focused Space's.
  std::optional<RuntimeWorkspace> workspace;
  // One per visible workspace, so one per display.
  std::vector<RuntimeView> views;
  std::uint64_t workspaces_revision = 0;
  std::vector<WorkspaceSummary> workspaces;
  std::uint64_t completed_request = 0;
  bool request_succeeded = true;
  WorkspaceCreation created;
  std::string error;

  bool operator==(const RuntimeState &) const = default;

  const RuntimeView *view(const RuntimeWorkspace &visible) const {
    const auto found = std::ranges::find(views, visible, &RuntimeView::workspace);
    return found == views.end() ? nullptr : &*found;
  }

  const RuntimeView *focused() const {
    return workspace ? view(*workspace) : nullptr;
  }
};
