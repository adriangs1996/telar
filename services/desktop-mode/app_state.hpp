#pragma once

#include <cstdint>
#include <string>
#include <vector>

struct WorkspaceSummary {
  std::uint64_t id = 0;
  std::string name;
  std::uint16_t tab_count = 0;
  std::string path;

  bool operator==(const WorkspaceSummary &) const = default;
};

struct AppState {
  std::uint64_t workspaces_revision = 0;
  std::vector<WorkspaceSummary> workspaces;
};
