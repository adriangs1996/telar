#pragma once

#include "app_state.hpp"
#include <optional>

struct RuntimeWorkspace {
  std::uint64_t id = 0;
  bool worktree = false;

  bool operator==(const RuntimeWorkspace &) const = default;
};

struct RuntimeTab {
  std::uint64_t id = 0;
  std::string label;
  std::vector<std::string> foregrounds;

  bool operator==(const RuntimeTab &) const = default;
};

struct RuntimeState {
  bool connected = false;
  std::optional<RuntimeWorkspace> workspace;
  std::string workspace_name;
  std::uint64_t active_tab = 0;
  std::vector<RuntimeTab> tabs;
  std::uint64_t workspaces_revision = 0;
  std::vector<WorkspaceSummary> workspaces;
  std::uint64_t completed_request = 0;
  bool request_succeeded = true;
  std::string error;

  bool operator==(const RuntimeState &) const = default;
};
