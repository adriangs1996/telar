#pragma once

#include "app_state.hpp"
#include <algorithm>
#include <chrono>
#include <memory>
#include <optional>

struct RuntimeWorkspace {
  std::uint64_t id = 0;
  bool worktree = false;

  bool operator==(const RuntimeWorkspace &) const = default;
  auto operator<=>(const RuntimeWorkspace &) const = default;
};

// The process in front of one of a tab's panes.
struct RuntimeForeground {
  std::uint64_t pane = 0;
  std::string name;

  bool operator==(const RuntimeForeground &) const = default;
};

struct RuntimeTab {
  std::uint64_t id = 0;
  std::string label;
  std::vector<RuntimeForeground> foregrounds;

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

// One agent of the runtime's latest agent snapshot. Status and reason keep the wire names, which
// are also what Lua sees.
struct RuntimeAgent {
  std::uint64_t pane = 0;
  std::uint64_t generation = 0;
  RuntimeWorkspace workspace;
  std::uint64_t tab = 0;
  std::uint16_t pane_index = 0;
  std::string workspace_label;
  std::string tab_label;
  std::string title;
  std::string cwd_label;
  std::string provider;
  std::string name;
  std::string status;
  std::string blocked_reason;
  std::string last_event;
  // The agent's closing words for its last turn.
  std::string final_message;
  // The worktree it works in, when the runtime tracks one; 0 otherwise.
  std::uint64_t work_tree = 0;
  std::string plan_step;
  std::uint16_t plan_done = 0;
  std::uint16_t plan_total = 0;
  // When the status last changed, on this process's clock.
  std::chrono::steady_clock::time_point status_changed{};

  bool operator==(const RuntimeAgent &) const = default;
};

// A workspace's own checkout: the branch it is on and whether it has uncommitted changes.
struct RuntimeCheckout {
  std::uint64_t workspace = 0;
  std::string branch;
  bool dirty = false;

  bool operator==(const RuntimeCheckout &) const = default;
};

// A worktree the runtime tracks, usually an agent's task, and how far it moved from its base.
struct RuntimeWorktree {
  std::uint64_t id = 0;
  std::uint64_t workspace = 0;
  std::string branch;
  std::string title;
  std::uint32_t diff_added = 0;
  std::uint32_t diff_removed = 0;
  std::uint32_t diff_files = 0;
  std::uint32_t commits_ahead = 0;
  // The last command run in it, "running" or "exited" with its exit code; empty without one.
  std::string command_label;
  std::string command_state;
  std::int32_t command_exit = 0;

  bool operator==(const RuntimeWorktree &) const = default;
};

// Immutable once published, so threads and copies of the state share one list.
using RuntimeAgents = std::shared_ptr<const std::vector<RuntimeAgent>>;

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
  std::vector<RuntimeCheckout> checkouts;
  std::vector<RuntimeWorktree> worktrees;
  std::uint64_t completed_request = 0;
  bool request_succeeded = true;
  WorkspaceCreation created;
  // In attention order; each snapshot is a new list, so equality compares identity.
  RuntimeAgents agents;
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
