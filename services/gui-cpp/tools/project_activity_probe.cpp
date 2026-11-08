#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstdint>
#include <cstddef>
#include <cstring>
#include <cmath>
#include <cstdio>

import std;
import telar.client.protocol;
import telar.config;
import telar.gui.core.primitives;
import telar.gui.terminal.screen;
import telar.gui.tools.probe_io;
import telar.gui.tools.probe_text;
import telar.gui.application.workspace_replica;
import telar.gui.core.metrics;
import telar.gui.presentation.activity_order;

namespace {

using namespace telar;
using namespace telar::gui;

std::size_t readCount(std::size_t maximum) {
  const auto count = probe::read<std::uint16_t>();
  if (count > maximum) {
    throw std::length_error{"ProjectProbeCountExceeded"};
  }

  return count;
}

template <Allocator Memory>
void readWorkspaces(WorkspaceReplica<Memory> &replica, Memory &memory) {
  Vector<WorkspaceListEntry, Memory> entries{AllocatorRef<WorkspaceListEntry, Memory>{memory}};
  std::deque<String<Memory>, AllocatorRef<String<Memory>, Memory>> paths{AllocatorRef<String<Memory>, Memory>{memory}};
  const auto count = readCount(WorkspaceReplica<Memory>::maximum_workspaces);
  for (std::size_t index = 0; index < count; ++index) {
    const auto identity = probe::read<std::uint64_t>();
    const auto &path = paths.emplace_back(probe::readText(memory));
    entries.push_back({.workspace = identity, .name = "project", .path = path});
  }

  Vector<WorktreeListEntry, Memory> tasks{AllocatorRef<WorktreeListEntry, Memory>{memory}};
  const auto task_count = readCount(WorkspaceReplica<Memory>::maximum_worktrees);
  for (std::size_t index = 0; index < task_count; ++index) {
    WorktreeListEntry task;
    task.worktree = probe::read<std::uint64_t>();
    task.source = probe::read<std::uint64_t>();
    const auto workspace = probe::read<std::uint64_t>();
    task.workspace = workspace == 0 ? std::nullopt : std::optional{workspace};
    task.state = static_cast<WorktreeState>(probe::read<std::uint8_t>());
    task.path = "/task";
    task.branch = "worktree-task";
    tasks.push_back(task);
  }

  replica.apply({.revision = 1, .entries = entries, .worktrees = tasks});
}

template <Allocator Memory>
Vector<Agent<Memory>, Memory> readAgents(Memory &memory) {
  constexpr std::size_t maximum_agents = AgentOrder::maximum_agents;
  Vector<Agent<Memory>, Memory> agents{AllocatorRef<Agent<Memory>, Memory>{memory}};
  const auto count = readCount(maximum_agents);
  agents.reserve(count);
  for (std::size_t index = 0; index < count; ++index) {
    auto &agent = agents.emplace_back(memory);
    agent.pane_id = probe::read<std::uint64_t>();
    agent.pane_generation = probe::read<std::uint64_t>();
    agent.location.workspace.kind = static_cast<WorkspaceLocation::Kind>(probe::read<std::uint8_t>());
    agent.location.workspace.id = probe::read<std::uint64_t>();
    agent.status = static_cast<AgentStatus>(probe::read<std::uint8_t>());
    agent.status_age_s = probe::read<std::uint32_t>();
    agent.work_tree = probe::read<std::uint64_t>();
  }

  return agents;
}

void run() {
  SystemAllocator memory;
  const auto project = probe::read<std::uint64_t>();
  const auto active = probe::read<std::uint8_t>() != 0;
  WorkspaceReplica replica{memory};
  readWorkspaces(replica, memory);
  const auto agents = readAgents(memory);
  const auto selected = active && replica.projectOf(project) == project;
  const auto activity = ProjectActivity::derive(replica, std::span<const Agent<SystemAllocator>>{agents}, project);
  ProjectActivity::Text storage;
  const auto summary = activity.summary(storage);
  probe::write(static_cast<std::uint8_t>(summary.has_value()));
  probe::writeText(summary.value_or(""));
  probe::writeText(activity.path ? activity.attentionLabel().view() : "");
  std::string_view color = "overlay1";
  if (activity.path && activity.urgent) {
    color = "inactive";
    if (selected) {
      color = palette_names[static_cast<std::size_t>(AgentStatusPresentation::color(agents[*activity.urgent].status))];
    }
  }

  probe::writeText(color);
}

}

int main() try {
  while (true) {
    const auto operation = std::getchar();
    if (operation == EOF) {
      return std::ferror(stdin) == 0 ? 0 : 1;
    }

    if (operation != 0) {
      throw std::invalid_argument{"UnknownProjectProbeOperation"};
    }

    run();
  }
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
