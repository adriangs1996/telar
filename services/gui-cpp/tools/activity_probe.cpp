#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_messages.hpp"
#include <cstdint>
#include "../core/memory.hpp"
#include <algorithm>
#include <limits>
#include "../core/terminal_size.hpp"
#include <atomic>
#include <exception>
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"
#include <array>
#include <concepts>
#include <utility>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include "../terminal/screen.hpp"
#include <string_view>
#include <stdexcept>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <tuple>
#include <compare>
#include "probe_io.hpp"
#include "probe_text.hpp"
#include <cstdio>
#include <deque>
#include <iostream>

#include "core/memory.hpp"


import telar.gui.application.workspace_replica;
import telar.gui.presentation.activity_order;

namespace {

using namespace telar;
using namespace telar::gui;
using probe::writeText;

template <Allocator Memory>
struct ActivityReplica {
  explicit ActivityReplica(Memory &memory)
      : workspaces(memory),
        agents(memory) {}

  WorkspaceReplica<Memory> workspaces;
  AgentReplica<Memory> agents;
  std::uint8_t slot = 0;
  std::optional<std::uint64_t> focused;
};

std::optional<std::uint64_t> readIdentity() {
  const auto value = probe::read<std::uint64_t>();

  return value == 0 ? std::nullopt : std::optional{value};
}

std::size_t readCount(std::size_t maximum) {
  const auto count = probe::read<std::uint16_t>();
  if (count > maximum) {
    throw std::length_error{"ProbeCountExceeded"};
  }

  return count;
}

template <Allocator Memory>
class ActivityInput {
public:
  explicit ActivityInput(Memory &memory)
      : memory_(memory),
        strings_(AllocatorRef<String<Memory>, Memory>{memory}) {}

  void read(ActivityReplica<Memory> &source) {
    source.slot = probe::read<std::uint8_t>();
    source.focused = readIdentity();
    Vector<WorkspaceListEntry, Memory> projects{AllocatorRef<WorkspaceListEntry, Memory>{memory_}};
    const auto project_count = readCount(WorkspaceReplica<Memory>::maximum_workspaces);
    projects.reserve(project_count);
    for (std::size_t index = 0; index < project_count; ++index) {
      projects.push_back(readWorkspace());
    }

    Vector<WorktreeListEntry, Memory> tasks{AllocatorRef<WorktreeListEntry, Memory>{memory_}};
    const auto task_count = readCount(WorkspaceReplica<Memory>::maximum_worktrees);
    tasks.reserve(task_count);
    for (std::size_t index = 0; index < task_count; ++index) {
      tasks.push_back(readWorktree());
    }

    Vector<AgentSnapshotEntry, Memory> agents{AllocatorRef<AgentSnapshotEntry, Memory>{memory_}};
    const auto agent_count = readCount(AgentReplica<Memory>::capacity);
    agents.reserve(agent_count);
    for (std::size_t index = 0; index < agent_count; ++index) {
      agents.push_back(readAgent(index));
    }

    source.workspaces.apply({.revision = 1, .entries = projects, .worktrees = tasks});
    source.agents.apply({.revision = 1, .entries = agents}, 0);
  }

private:
  std::string_view text() {
    return strings_.emplace_back(probe::readText(memory_));
  }

  WorkspaceListEntry readWorkspace() {
    WorkspaceListEntry entry;
    entry.workspace = probe::read<std::uint64_t>();
    entry.name = text();
    entry.path = text();
    entry.tab_count = probe::read<std::uint16_t>();
    entry.branch = text();
    entry.dirty = probe::read<std::uint8_t>() != 0;

    return entry;
  }

  WorktreeListEntry readWorktree() {
    WorktreeListEntry entry;
    entry.worktree = probe::read<std::uint64_t>();
    entry.source = probe::read<std::uint64_t>();
    entry.workspace = readIdentity();
    entry.created_by = readIdentity();
    if (probe::read<std::uint8_t>() != 0) {
      CoordinatorReference reference;
      reference.session_id = probe::read<decltype(reference.session_id)>();
      reference.pane_id = probe::read<std::uint64_t>();
      reference.pane_generation = probe::read<std::uint64_t>();
      entry.coordinator = reference;
    }

    entry.state = static_cast<WorktreeState>(probe::read<std::uint8_t>());
    entry.path = text();
    entry.branch = text();
    entry.base = text();
    entry.title = text();
    entry.diff_added = probe::read<std::uint32_t>();
    entry.diff_removed = probe::read<std::uint32_t>();
    entry.diff_files = probe::read<std::uint32_t>();
    entry.commits_ahead = probe::read<std::uint32_t>();
    entry.command_label = text();
    entry.command_state = static_cast<CommandState>(probe::read<std::uint8_t>());
    entry.command_exit = probe::read<std::int32_t>();

    return entry;
  }

  static AgentSnapshotEntry readAgent(std::size_t index) {
    AgentSnapshotEntry entry;
    entry.pane_id = probe::read<std::uint64_t>();
    entry.pane_generation = probe::read<std::uint64_t>();
    entry.session_id = probe::read<decltype(entry.session_id)>();
    entry.location.workspace.kind = static_cast<WorkspaceLocation::Kind>(probe::read<std::uint8_t>());
    entry.location.workspace.id = probe::read<std::uint64_t>();
    entry.location.tab_id = 1;
    entry.pane_index = static_cast<std::uint16_t>(index + 1);
    entry.status = static_cast<AgentStatus>(probe::read<std::uint8_t>());
    entry.status_age_s = probe::read<std::uint32_t>();
    entry.work_tree = probe::read<std::uint64_t>();
    entry.sequence = 1;

    return entry;
  }

  Memory &memory_;
  std::deque<String<Memory>, AllocatorRef<String<Memory>, Memory>> strings_;
};

template <Allocator Memory>
void writeWorktree(const Worktree<Memory> &row) {
  probe::write(row.id);
  probe::write(row.source);
  probe::write(row.workspace.value_or(0));
  probe::write(row.created_by.value_or(0));
  probe::write(static_cast<std::uint8_t>(row.coordinator.has_value()));
  if (row.coordinator) {
    probe::write(row.coordinator->session_id);
    probe::write(row.coordinator->pane_id);
    probe::write(row.coordinator->pane_generation);
  }

  probe::write(static_cast<std::uint8_t>(row.state));
  writeText(row.path);
  writeText(row.branch);
  writeText(row.base);
  writeText(row.title);
  writeText(row.command_label);
  writeText(row.handle());
  writeText(row.displayName());
  probe::write(row.diff_added);
  probe::write(row.diff_removed);
  probe::write(row.diff_files);
  probe::write(row.commits_ahead);
  probe::write(static_cast<std::uint8_t>(row.command_state));
  probe::write(row.command_exit);
}

template <Allocator Memory>
void writeWorkspaces(const WorkspaceReplica<Memory> &replica) {
  probe::write(static_cast<std::uint16_t>(replica.entries().size()));
  probe::write(static_cast<std::uint16_t>(replica.projects().size()));
  probe::write(static_cast<std::uint16_t>(replica.dropped()));
  probe::write(static_cast<std::uint16_t>(replica.worktrees().size()));
  for (const auto &entry : replica.entries()) {
    probe::write(entry.location.id);
    writeText(entry.name);
    writeText(entry.path);
    writeText(entry.branch);
    probe::write(entry.tab_count);
    probe::write(static_cast<std::uint8_t>(entry.dirty));
  }

  for (const auto &row : replica.worktrees()) {
    writeWorktree(row);
  }
}

template <Allocator Memory>
void writeOrder(const typename ActivityOrder<Memory>::Plan &plan) {
  constexpr auto absent_index = std::numeric_limits<std::uint16_t>::max();
  probe::write(static_cast<std::uint16_t>(plan.count));
  for (const auto &entry : plan.view()) {
    probe::write(static_cast<std::uint8_t>(entry.source));
    probe::write(static_cast<std::uint16_t>(entry.agent.value_or(absent_index)));
    probe::write(static_cast<std::uint16_t>(entry.worktree.value_or(absent_index)));
    probe::write(entry.project.value_or(0));
    probe::write(static_cast<std::uint8_t>(entry.card));
    probe::write(static_cast<std::uint16_t>(entry.parent.value_or(absent_index)));
    probe::write(static_cast<std::uint16_t>(entry.depth));
    probe::write(static_cast<std::uint8_t>(entry.coordinator));
    probe::write(static_cast<std::uint8_t>(entry.first_in_project));
  }
}

template <Allocator Memory>
void runCase(Memory &memory, std::size_t count) {
  using Order = ActivityOrder<Memory>;
  if (count > Order::maximum_sources) {
    throw std::length_error{"TooManyActivitySources"};
  }

  const auto active = probe::read<std::uint8_t>();
  ActivityInput input{memory};
  Vector<Owned<ActivityReplica<Memory>, Memory>, Memory> replicas{AllocatorRef<Owned<ActivityReplica<Memory>, Memory>, Memory>{memory}};
  Vector<typename Order::Source, Memory> sources{AllocatorRef<typename Order::Source, Memory>{memory}};
  replicas.reserve(count);
  sources.reserve(count);
  for (std::size_t index = 0; index < count; ++index) {
    auto replica = makeOwned<ActivityReplica<Memory>>(memory, memory);
    input.read(*replica);
    sources.push_back({.slot = replica->slot, .agents = replica->agents.entries(), .workspaces = replica->workspaces, .focused = replica->focused});
    replicas.push_back(std::move(replica));
  }

  probe::write(static_cast<std::uint8_t>(count));
  for (const auto &replica : replicas) {
    writeWorkspaces(replica->workspaces);
  }

  typename Order::Plan plan;
  Order::write(sources, active, plan);
  writeOrder<Memory>(plan);
}

}

int main() try {
  SystemAllocator memory;
  while (true) {
    const auto count = std::getchar();
    if (count == EOF) {
      return std::ferror(stdin) == 0 ? 0 : 1;
    }

    runCase(memory, static_cast<std::size_t>(count));
  }
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
