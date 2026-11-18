module telar.gui.foundation.model;

import std;

import telar.base.memory.allocators;
import telar.wire.agents;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.gui.foundation.core;
import telar.base.ds;

namespace telar::gui::inline foundation::inline model {

  template <Allocator Memory>
  AgentReplica<Memory>::AgentReplica(Memory& memory)
      : memory_(memory),
        entries_(AllocatorRef<Agent<Memory>, Memory>{memory}),
        staging_(AllocatorRef<Agent<Memory>, Memory>{memory}) {}

  template <Allocator Memory>
  const Vector<Agent<Memory>, Memory>& AgentReplica<Memory>::entries() const noexcept {
    return entries_;
  }

  template <Allocator Memory>
  typename Vector<Agent<Memory>, Memory>::const_iterator AgentReplica<Memory>::begin() const noexcept {
    return entries_.begin();
  }

  template <Allocator Memory>
  typename Vector<Agent<Memory>, Memory>::const_iterator AgentReplica<Memory>::end() const noexcept {
    return entries_.end();
  }

  template <Allocator Memory>
  std::uint64_t AgentReplica<Memory>::revision() const noexcept {
    return revision_;
  }

  template <Allocator Memory>
  std::span<const AgentStatusChange> AgentReplica<Memory>::statusChanges() const noexcept {
    return std::span{status_changes_}.first(status_change_count_);
  }

  template <Allocator Memory>
  void AgentReplica<Memory>::resetSource() noexcept {
    revision_ = 0;
    now_ns_ = 0;
    retain_clocks_ = false;
    status_change_count_ = 0;
  }

  template <Allocator Memory>
  bool AgentReplica<Memory>::apply(const AgentSnapshot& snapshot, std::uint64_t now_ns) {
    if (snapshot.revision <= revision_) {
      return false;
    }

    if (snapshot.entries.size() > capacity) {
      throw std::length_error{"TooManyAgents"};
    }

    validate(snapshot);
    prepareStaging(snapshot.entries.size());
    ds::Array<AgentStatusChange, capacity> status_changes;
    std::size_t status_change_count = 0;
    const auto sample_ns = std::max(now_ns_, now_ns);

    for (std::size_t index = 0; index < snapshot.entries.size(); ++index) {
      const auto& entry = snapshot.entries[index];
      auto& agent = staging_[index];

      assign(agent, entry);
      const auto previous = std::ranges::find_if(entries_, [&](const auto& candidate) {
        return candidate.pane_id == entry.pane_id && candidate.pane_generation == entry.pane_generation;
      });

      agent.status_clock = retain_clocks_ && previous != entries_.end() ? previous->status_clock : StatusAge{};
      agent.status_clock.observe({.pane_id = agent.pane_id, .pane_generation = agent.pane_generation, .status = agent.status, .provider = agent.provider_kind, .reported_seconds = agent.status_age_s}, sample_ns);

      if (retain_clocks_ && previous != entries_.end() && previous->status != agent.status) {
        status_changes.atMut(status_change_count++) = {.pane_id = agent.pane_id, .pane_generation = agent.pane_generation, .pane_index = agent.pane_index, .provider = agent.provider_kind, .previous = previous->status, .current = agent.status};
      }
    }

    entries_.swap(staging_);
    std::ranges::copy(status_changes.viewMut().first(status_change_count), status_changes_.viewMut().begin());
    status_change_count_ = status_change_count;
    revision_ = snapshot.revision;
    now_ns_ = sample_ns;
    retain_clocks_ = true;

    return true;
  }

  template <Allocator Memory>
  void AgentReplica<Memory>::validate(const AgentSnapshot& snapshot) {
    for (std::size_t index = 0; index < snapshot.entries.size(); ++index) {
      const auto& entry = snapshot.entries[index];

      BodySchema<AgentSnapshotEntry>::validate(entry);
      for (const auto& previous : snapshot.entries.first(index)) {
        if (previous.pane_id == entry.pane_id && previous.pane_generation == entry.pane_generation) {
          throw std::invalid_argument{"DuplicateAgent"};
        }
      }
    }
  }

  template <Allocator Memory>
  void AgentReplica<Memory>::prepareStaging(std::size_t count) {
    while (staging_.size() > count) {
      staging_.pop_back();
    }

    staging_.reserve(count);
    while (staging_.size() < count) {
      staging_.emplace_back(memory_);
    }
  }

  template <Allocator Memory>
  void AgentReplica<Memory>::assign(Agent<Memory>& agent, const AgentSnapshotEntry& entry) {
    agent.pane_id = entry.pane_id;
    agent.pane_generation = entry.pane_generation;
    agent.pane_index = entry.pane_index;
    agent.session_id = entry.session_id;
    agent.work_tree = entry.work_tree;
    agent.location = entry.location;
    agent.status = entry.status;
    agent.blocked_reason = entry.blocked_reason;
    agent.provider_kind = entry.provider;
    agent.attachments = entry.attachments;
    agent.title_state = entry.title_state;
    agent.title = entry.session_title;
    agent.provider_name = entry.provider_name;
    agent.workspace_label = entry.workspace_label;
    agent.display_name = entry.display_name;
    agent.icon = entry.icon;
    agent.detail = entry.last_event;
    agent.plan_step = entry.plan_step;
    agent.final_message = entry.final_message;
    agent.plan_done = entry.plan_done;
    agent.plan_total = entry.plan_total;
    agent.status_age_s = entry.status_age_s;
  }

  std::span<const std::uint16_t> ListedPane::ports() const noexcept {
    return std::span{port_values}.first(port_count);
  }

  template <Allocator Memory>
  PaneListReplica<Memory>::PaneListReplica(Memory& memory)
      : entries_(AllocatorRef<ListedPane, Memory>{memory}) {}

  template <Allocator Memory>
  std::span<const ListedPane> PaneListReplica<Memory>::entries() const noexcept {
    return entries_;
  }

  template <Allocator Memory>
  std::uint64_t PaneListReplica<Memory>::revision() const noexcept {
    return revision_;
  }

  template <Allocator Memory>
  const ListedPane* PaneListReplica<Memory>::find(std::uint64_t pane_id, std::uint64_t generation) const noexcept {
    const auto found = std::ranges::find_if(entries_, [&](const auto& entry) {
      return entry.pane_id == pane_id && entry.pane_generation == generation;
    });

    return found == entries_.end() ? nullptr : &*found;
  }

  template <Allocator Memory>
  void PaneListReplica<Memory>::resetSource() noexcept {
    revision_ = 0;
  }

  template <Allocator Memory>
  bool PaneListReplica<Memory>::apply(const PaneList& list, std::uint64_t now_ns) {
    if (list.revision <= revision_) {
      return false;
    }

    if (list.entries.size() > capacity) {
      throw std::length_error{"TooManyListedPanes"};
    }

    for (std::size_t index = 0; index < list.entries.size(); ++index) {
      const auto& entry = list.entries[index];

      for (const auto& previous : list.entries.first(index)) {
        if (previous.pane_id == entry.pane_id) {
          throw std::invalid_argument{"DuplicateListedPane"};
        }
      }
    }

    // Reserving first keeps the previous list whole when storage runs out.
    entries_.reserve(list.entries.size());
    entries_.clear();
    for (const auto& entry : list.entries) {
      auto& pane = entries_.emplace_back();

      pane.pane_id = entry.pane_id;
      pane.pane_generation = entry.pane_generation;
      pane.location = entry.location;
      pane.foreground.assign(entry.foreground);
      pane.age = {.age_ns = std::uint64_t{entry.foreground_age_s} * StatusAgeInterval::nanoseconds_per_second, .sampled_ns = now_ns};
      pane.shell = entry.shell;
      pane.port_count = static_cast<std::uint8_t>(std::min(entry.ports.size(), pane.port_values.size()));
      std::ranges::copy(entry.ports.first(pane.port_count), pane.port_values.viewMut().begin());
    }

    revision_ = list.revision;

    return true;
  }

  template <Allocator Memory>
  WorkspaceReplica<Memory>::WorkspaceReplica(Memory& memory)
      : memory_(memory),
        entries_(AllocatorRef<Workspace<Memory>, Memory>{memory}),
        staging_entries_(AllocatorRef<Workspace<Memory>, Memory>{memory}),
        worktrees_(AllocatorRef<Worktree<Memory>, Memory>{memory}),
        staging_worktrees_(AllocatorRef<Worktree<Memory>, Memory>{memory}) {}

  template <Allocator Memory>
  const Vector<Workspace<Memory>, Memory>& WorkspaceReplica<Memory>::entries() const noexcept {
    return entries_;
  }

  template <Allocator Memory>
  std::span<const Workspace<Memory>> WorkspaceReplica<Memory>::projects() const noexcept {
    return std::span<const Workspace<Memory>>{entries_}.first(project_count_);
  }

  template <Allocator Memory>
  const Vector<Worktree<Memory>, Memory>& WorkspaceReplica<Memory>::worktrees() const noexcept {
    return worktrees_;
  }

  template <Allocator Memory>
  std::span<Workspace<Memory>> WorkspaceReplica<Memory>::entriesMut() noexcept {
    return entries_;
  }

  template <Allocator Memory>
  typename Vector<Workspace<Memory>, Memory>::const_iterator WorkspaceReplica<Memory>::begin() const noexcept {
    return entries_.begin();
  }

  template <Allocator Memory>
  typename Vector<Workspace<Memory>, Memory>::const_iterator WorkspaceReplica<Memory>::end() const noexcept {
    return entries_.end();
  }

  template <Allocator Memory>
  std::uint64_t WorkspaceReplica<Memory>::revision() const noexcept {
    return revision_;
  }

  template <Allocator Memory>
  std::size_t WorkspaceReplica<Memory>::dropped() const noexcept {
    return dropped_;
  }

  template <Allocator Memory>
  const Worktree<Memory>* WorkspaceReplica<Memory>::worktree(std::uint64_t identity) const noexcept {
    if (identity == 0) {
      return nullptr;
    }

    const auto row = std::ranges::find(worktrees_, identity, &Worktree<Memory>::id);

    return row == worktrees_.end() ? nullptr : &*row;
  }

  template <Allocator Memory>
  const Worktree<Memory>* WorkspaceReplica<Memory>::worktreeOfWorkspace(std::uint64_t identity) const noexcept {
    const auto row = std::ranges::find(worktrees_, ds::Option{identity}, &Worktree<Memory>::workspace);

    return row == worktrees_.end() ? nullptr : &*row;
  }

  template <Allocator Memory>
  std::size_t WorkspaceReplica<Memory>::indexOf(std::uint64_t identity) const noexcept {
    const auto row = std::ranges::find_if(entries_, [identity](const auto& entry) {
      return entry.location.kind == WorkspaceLocation::Kind::workspace && entry.location.id == identity;
    });

    return row == entries_.end() ? entries_.size() : static_cast<std::size_t>(row - entries_.begin());
  }

  template <Allocator Memory>
  std::uint64_t WorkspaceReplica<Memory>::projectOf(std::uint64_t workspace) const noexcept {
    const auto* row = worktreeOfWorkspace(workspace);

    return row != nullptr && indexOf(row->source) < entries_.size() ? row->source : workspace;
  }

  template <Allocator Memory>
  void WorkspaceReplica<Memory>::resetSource() noexcept {
    revision_ = 0;
  }

  template <Allocator Memory>
  bool WorkspaceReplica<Memory>::apply(const WorkspaceList& snapshot) {
    if (snapshot.revision <= revision_) {
      return false;
    }

    validateCapacity(snapshot);
    for (const auto& row : snapshot.worktrees) {
      static_cast<void>(ValueCodec<WorktreeListEntry>::encodedSize(row));
    }

    ds::Array<const WorkspaceListEntry*, maximum_workspaces> ordered{};
    std::size_t count = 0;

    for (const auto& entry : snapshot.entries) {
      if (!holdsWorktree(snapshot, entry.workspace)) {
        ordered.atMut(count++) = &entry;
      }
    }

    const auto project_count = count;

    for (const auto& entry : snapshot.entries) {
      if (holdsWorktree(snapshot, entry.workspace)) {
        ordered.atMut(count++) = &entry;
      }
    }

    const auto retained = retainedCount(std::span{ordered}.first(count));

    prepare(staging_entries_, retained, memory_);
    prepare(staging_worktrees_, snapshot.worktrees.size(), memory_);
    for (std::size_t index = 0; index < retained; ++index) {
      assign(staging_entries_[index], *ordered[index]);
    }

    for (std::size_t index = 0; index < snapshot.worktrees.size(); ++index) {
      assign(staging_worktrees_[index], snapshot.worktrees[index]);
    }

    entries_.swap(staging_entries_);
    worktrees_.swap(staging_worktrees_);
    project_count_ = std::min(project_count, retained);
    dropped_ = count - retained;
    revision_ = snapshot.revision;

    return true;
  }

  template <Allocator Memory>
  void WorkspaceReplica<Memory>::validateCapacity(const WorkspaceList& snapshot) {
    if (snapshot.entries.size() > maximum_workspaces) {
      throw std::length_error{"TooManyWorkspaces"};
    }

    if (snapshot.worktrees.size() > maximum_worktrees) {
      throw std::length_error{"TooManyWorktrees"};
    }
  }

  template <Allocator Memory>
  bool WorkspaceReplica<Memory>::holdsWorktree(const WorkspaceList& snapshot, std::uint64_t identity) noexcept {
    return std::ranges::any_of(snapshot.worktrees, [identity](const auto& row) {
      return row.workspace == identity;
    });
  }

  template <Allocator Memory>
  std::size_t WorkspaceReplica<Memory>::retainedCount(std::span<const WorkspaceListEntry* const> ordered) {
    std::size_t path_bytes = 0;

    for (std::size_t index = 0; index < ordered.size(); ++index) {
      const auto& entry = *ordered[index];

      static_cast<void>(ValueCodec<WorkspaceListEntry>::encodedSize(entry));
      if (entry.path.size() > path_pool_bytes - path_bytes) {
        return index;
      }

      for (const auto* previous : ordered.first(index)) {
        if (previous->workspace == entry.workspace) {
          throw std::invalid_argument{"DuplicateWorkspace"};
        }
      }

      path_bytes += entry.path.size();
    }

    return ordered.size();
  }

  template <Allocator Memory>
  template <typename Row>
  void WorkspaceReplica<Memory>::prepare(Vector<Row, Memory>& rows, std::size_t count, Memory& memory) {
    while (rows.size() > count) {
      rows.pop_back();
    }

    rows.reserve(count);
    while (rows.size() < count) {
      rows.emplace_back(memory);
    }
  }

  template <Allocator Memory>
  void WorkspaceReplica<Memory>::assign(Workspace<Memory>& row, const WorkspaceListEntry& entry) {
    row.location = {.kind = WorkspaceLocation::Kind::workspace, .id = entry.workspace};
    row.name = entry.name;
    row.path = entry.path;
    row.branch = entry.branch;
    row.tab_count = entry.tab_count;
    row.dirty = entry.dirty;
  }

  template <Allocator Memory>
  void WorkspaceReplica<Memory>::assign(Worktree<Memory>& row, const WorktreeListEntry& entry) {
    row.id = entry.worktree;
    row.source = entry.source;
    row.workspace = entry.workspace;
    row.created_by = entry.created_by;
    row.coordinator = entry.coordinator;
    row.state = entry.state;
    row.path = entry.path.substr(entry.path.size() - std::min(entry.path.size(), Worktree<Memory>::retained_path_bytes));
    row.branch = entry.branch;
    row.base = entry.base;
    row.title = entry.title;
    row.diff_added = entry.diff_added;
    row.diff_removed = entry.diff_removed;
    row.diff_files = entry.diff_files;
    row.commits_ahead = entry.commits_ahead;
    row.command_label = entry.command_label;
    row.command_state = entry.command_state;
    row.command_exit = entry.command_exit;
  }

  template class AgentReplica<Memory>;
  template class AgentReplica<ConcurrentMemory>;
  template class PaneListReplica<Memory>;
  template class PaneListReplica<ConcurrentMemory>;
  template class WorkspaceReplica<Memory>;
  template class WorkspaceReplica<ConcurrentMemory>;

}
