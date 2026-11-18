module telar.gui.features.activity;

import std;
import telar.tbc;
import telar.gui.foundation.core;
import telar.gui.foundation.model;
import telar.base.ds;

namespace telar::gui::features::activity {

  auto AgentOrder::Plan::view() const noexcept -> std::span<const Entry> {
    return std::span{entries}.first(count);
  }

  auto AgentOrder::attention(AgentStatus status) noexcept -> Attention {
    switch (status) {
    case AgentStatus::blocked:
    case AgentStatus::failed:
      return Attention::needs_input;
    case AgentStatus::working:
      return Attention::working;
    case AgentStatus::done:
      return Attention::done;
    case AgentStatus::ready:
      return Attention::ready;
    default:
      return Attention::unknown;
    }
  }

  bool AgentOrder::stacked(AgentStatus status) noexcept {
    const auto group = attention(status);

    return group == Attention::needs_input || group == Attention::working;
  }

  template <Allocator Memory>
  tbc::view<const Worktree<Memory>*, tbc::lt::a> AgentOrder::taskRow(tbc::view<const WorkspaceReplica<Memory>&, tbc::lt::a> workspaces, const Agent<Memory>& agent) noexcept {
    if (const auto* row = workspaces.worktree(agent.work_tree)) {
      return row;
    }

    return agent.location.workspace.kind == WorkspaceLocation::Kind::workspace ? workspaces.worktreeOfWorkspace(agent.location.workspace.id) : nullptr;
  }

  template <Allocator Memory>
  auto AgentOrder::priority(const Agent<Memory>& agent) noexcept -> Priority {
    return std::tuple{attention(agent.status), agent.status_age_s, agent.pane_id, agent.pane_generation};
  }

  template <Allocator Memory>
  auto AgentOrder::arrange(std::span<const Agent<Memory>> agents, const WorkspaceReplica<Memory>& workspaces) noexcept -> Plan {
    Plan plan;

    plan.count = std::min(agents.size(), maximum_agents);
    const auto entries = std::span{plan.entries}.first(plan.count);

    for (std::size_t index = 0; index < plan.count; ++index) {
      const auto& agent = agents[index];
      const auto card = taskRow(workspaces, agent) != nullptr ? ActivityCard::task : ActivityCard::agent;
      const auto project = projectOf(workspaces, agent);

      entries[index] = {.agent = index, .project = project, .card = card};
    }

    for (auto& entry : entries) {
      entry.creator = creatorOf(agents, workspaces, entries, entry);
    }

    std::ranges::sort(entries, [&](const Entry& left, const Entry& right) {
      return lessThan(agents, workspaces, left, right);
    });

    for (std::size_t index = 0; index < entries.size(); ++index) {
      entries[index].first_in_project = index == 0 || entries[index].project != entries[index - 1].project;
    }

    return plan;
  }

  template <Allocator Memory>
  std::size_t AgentOrder::projectRank(ds::Option<std::uint64_t> identity, std::span<const Workspace<Memory>> workspaces) noexcept {
    if (identity) {
      for (std::size_t index = 0; index < workspaces.size(); ++index) {
        if (workspaces[index].location.kind == WorkspaceLocation::Kind::workspace && *identity == workspaces[index].location.id) {
          return index;
        }
      }
    }

    return unknown_project;
  }

  template <Allocator Memory>
  ds::Option<std::uint64_t> AgentOrder::projectOf(const WorkspaceReplica<Memory>& workspaces, const Agent<Memory>& agent) noexcept {
    if (const auto* row = workspaces.worktree(agent.work_tree)) {
      return row->source;
    }

    if (agent.location.workspace.kind != WorkspaceLocation::Kind::workspace) {
      return ds::none;
    }

    const auto project = workspaces.projectOf(agent.location.workspace.id);

    return workspaces.indexOf(project) < workspaces.entries().size() ? ds::Option{project} : ds::none;
  }

  template <Allocator Memory>
  ds::Option<std::size_t> AgentOrder::creatorOf(std::span<const Agent<Memory>> agents, const WorkspaceReplica<Memory>& workspaces, std::span<const Entry> entries, const Entry& entry) noexcept {
    const auto* row = entry.card == ActivityCard::agent ? nullptr : taskRow(workspaces, agents[entry.agent]);
    if (row == nullptr) {
      return ds::none;
    }

    for (const auto& candidate : entries) {
      const auto& parent = agents[candidate.agent];

      if (candidate.agent == entry.agent || candidate.card != ActivityCard::agent || candidate.project != entry.project) {
        continue;
      }

      if (row->coordinator) {
        const auto& reference = *row->coordinator;
        if (parent.pane_id == reference.pane_id && parent.pane_generation == reference.pane_generation && parent.session_id == reference.session_id) {
          return candidate.agent;
        }
      } else if (row->created_by == parent.pane_id) {
        return candidate.agent;
      }
    }

    return ds::none;
  }

  template <Allocator Memory>
  bool AgentOrder::lessThan(std::span<const Agent<Memory>> agents, const WorkspaceReplica<Memory>& workspaces, const Entry& left, const Entry& right) noexcept {
    const auto rows = std::span<const Workspace<Memory>>{workspaces.entries()};
    const auto left_rank = projectRank(left.project, rows);
    const auto right_rank = projectRank(right.project, rows);
    if (left_rank != right_rank) {
      return left_rank < right_rank;
    }

    const auto left_orphan = left.card != ActivityCard::agent && !left.creator;
    const auto right_orphan = right.card != ActivityCard::agent && !right.creator;
    if (left_orphan != right_orphan) {
      return !left_orphan;
    }

    if (!left_orphan) {
      const auto left_root = left.creator.valueOr(left.agent);
      const auto right_root = right.creator.valueOr(right.agent);
      if (left_root != right_root) {
        return priority(agents[left_root]) < priority(agents[right_root]);
      }

      if ((left.card == ActivityCard::agent) != (right.card == ActivityCard::agent)) {
        return left.card == ActivityCard::agent;
      }
    }

    return priority(agents[left.agent]) < priority(agents[right.agent]);
  }

  template <Allocator Memory>
  auto ActivityOrder<Memory>::Plan::view() const noexcept -> std::span<const Entry> {
    return std::span{entries}.first(count);
  }

  template <Allocator Memory>
  void ActivityOrder<Memory>::write(std::span<const Source> sources, std::uint8_t active_slot, Plan& output) {
    if (sources.size() > maximum_sources) {
      throw std::length_error{"TooManyActivitySources"};
    }

    ActivityOrder order{sources, output};

    order.collect(active_slot);
    order.findParents();
    order.breakCycles();
    order.emitForest();
  }

  template <Allocator Memory>
  ActivityOrder<Memory>::ActivityOrder(std::span<const Source> sources, Plan& output)
      : sources_(sources),
        output_(output) {}

  template <Allocator Memory>
  void ActivityOrder<Memory>::collect(std::uint8_t active_slot) {
    for (std::size_t source_index = 0; source_index < sources_.size(); ++source_index) {
      const auto& source = sources_[source_index];
      if (source.agents.size() > AgentOrder::maximum_agents) {
        throw std::length_error{"TooManyAgents"};
      }

      // Another machine's row in the sidebar stacks its working agents, so its cards here are
      // only the agents that wait on the person; its tracked commands stay on that machine.
      const bool active = source.slot == active_slot;
      const auto fleet = AgentOrder::arrange(source.agents, source.workspaces);
      const auto& worktrees = source.workspaces.worktrees();
      std::array<bool, WorkspaceReplica<Memory>::maximum_worktrees> represented{};

      for (const auto& entry : fleet.view()) {
        if (!active && AgentOrder::attention(source.agents[entry.agent].status) != AgentOrder::Attention::needs_input) {
          continue;
        }

        auto& node = nodes_[count_++];

        node = {.source = source_index, .agent = entry.agent, .project = entry.project, .card = entry.card};
        if (const auto* row = AgentOrder::taskRow(source.workspaces, source.agents[entry.agent])) {
          const auto index = static_cast<std::size_t>(row - worktrees.data());

          node.worktree = index;
          represented[index] = true;
        }
      }

      for (std::size_t index = 0; index < worktrees.size() && active; ++index) {
        const auto& row = worktrees[index];
        if (!represented[index] && row.command_state != CommandState::none) {
          nodes_[count_++] = {.source = source_index, .worktree = index, .project = row.source, .card = ActivityCard::task};
        }
      }
    }
  }

  template <Allocator Memory>
  auto ActivityOrder<Memory>::identityAt(std::size_t index) const noexcept {
    const auto& node = nodes_[index];
    if (!node.agent) {
      std::terminate();
    }

    const auto& agent = sources_[node.source].agents[*node.agent];

    return std::tuple{agent.session_id, agent.pane_id, agent.pane_generation};
  }

  template <Allocator Memory>
  const Worktree<Memory>* ActivityOrder<Memory>::rowOf(const Entry& entry) const noexcept {
    const auto& source = sources_[entry.source];

    if (entry.worktree) {
      return &source.workspaces.worktrees()[*entry.worktree];
    }

    return entry.agent ? AgentOrder::taskRow(source.workspaces, source.agents[*entry.agent]) : nullptr;
  }

  template <Allocator Memory>
  ds::Option<std::size_t> ActivityOrder<Memory>::parentOf(std::span<const std::size_t> agents, std::size_t index) const noexcept {
    const auto& entry = nodes_[index];
    const auto* row = rowOf(entry);
    if (row == nullptr) {
      return ds::none;
    }

    if (row->coordinator) {
      const auto& reference = *row->coordinator;
      const auto target = std::tuple{reference.session_id, reference.pane_id, reference.pane_generation};
      auto candidate = std::ranges::lower_bound(agents, target, {}, [this](std::size_t agent) {
        return identityAt(agent);
      });

      while (candidate != agents.end() && identityAt(*candidate) == target) {
        if (*candidate != index) {
          return *candidate;
        }

        ++candidate;
      }

      return ds::none;
    }

    if (!row->created_by) {
      return ds::none;
    }

    std::size_t start = index;

    while (start != 0 && nodes_[start - 1].source == entry.source) {
      --start;
    }

    for (std::size_t parent = start; parent < count_ && nodes_[parent].source == entry.source; ++parent) {
      const auto& candidate = nodes_[parent];
      if (candidate.agent && parent != index && candidate.card == ActivityCard::agent && candidate.project == entry.project && sources_[entry.source].agents[*candidate.agent].pane_id == *row->created_by) {
        return parent;
      }
    }

    return ds::none;
  }

  template <Allocator Memory>
  void ActivityOrder<Memory>::findParents() {
    std::array<std::size_t, maximum_entries> agents{};
    std::size_t agent_count = 0;

    for (std::size_t index = 0; index < count_; ++index) {
      if (nodes_[index].agent) {
        agents[agent_count++] = index;
      }
    }

    const auto indices = std::span{agents}.first(agent_count);

    std::ranges::sort(indices, [this](std::size_t left, std::size_t right) {
      return std::tuple{identityAt(left), left} < std::tuple{identityAt(right), right};
    });

    for (std::size_t index = 0; index < count_; ++index) {
      nodes_[index].parent = parentOf(indices, index);
    }
  }

  template <Allocator Memory>
  void ActivityOrder<Memory>::breakChainCycle(std::size_t start, std::span<Visit> visits, std::span<std::size_t> path) noexcept {
    std::size_t path_length = 0;
    ds::Option<std::size_t> current{start};

    while (current) {
      const auto index = *current;
      if (visits[index] != Visit::unseen) {
        if (visits[index] == Visit::visiting) {
          nodes_[index].parent.reset();
        }

        break;
      }

      visits[index] = Visit::visiting;
      path[path_length++] = index;
      current = nodes_[index].parent;
    }

    for (const auto index : path.first(path_length)) {
      visits[index] = Visit::finished;
    }
  }

  template <Allocator Memory>
  void ActivityOrder<Memory>::breakCycles() noexcept {
    std::array<Visit, maximum_entries> visits{};
    std::array<std::size_t, maximum_entries> path{};

    for (std::size_t start = 0; start < count_; ++start) {
      if (visits[start] != Visit::finished) {
        breakChainCycle(start, visits, path);
      }
    }
  }

  template <Allocator Memory>
  auto ActivityOrder<Memory>::linkChildren() noexcept -> Children {
    Children children;

    for (std::size_t index = 0; index < count_; ++index) {
      if (const auto parent = nodes_[index].parent) {
        nodes_[*parent].coordinator = true;
        if (const auto last = children.last[*parent]) {
          children.next[*last] = index;
        } else {
          children.first[*parent] = index;
        }

        children.last[*parent] = index;
      }
    }

    return children;
  }

  template <Allocator Memory>
  void ActivityOrder<Memory>::emitForest() noexcept {
    const auto children = linkChildren();
    std::array<std::size_t, maximum_entries> positions{};
    ds::Option<std::size_t> previous_source;
    ds::Option<std::uint64_t> previous_project;

    output_.count = 0;
    for (std::size_t root_index = 0; root_index < count_; ++root_index) {
      const auto& root = nodes_[root_index];
      if (root.parent) {
        continue;
      }

      auto current = root_index;
      std::size_t depth = 0;

      while (true) {
        auto entry = nodes_[current];

        entry.depth = depth;
        entry.parent = entry.parent ? ds::Option{positions[*entry.parent]} : ds::none;
        positions[current] = output_.count;
        entry.first_in_project = depth == 0 && (output_.count == 0 || previous_source != root.source || previous_project != root.project);
        output_.entries[output_.count++] = entry;
        if (const auto child = children.first[current]) {
          current = *child;
          ++depth;
          continue;
        }

        while (current != root_index && !children.next[current]) {
          current = *nodes_[current].parent;
          --depth;
        }

        if (current == root_index) {
          break;
        }

        current = *children.next[current];
      }

      previous_source = root.source;
      previous_project = root.project;
    }
  }

  template tbc::view<const Worktree<Memory>*, tbc::lt::a> AgentOrder::taskRow<Memory>(tbc::view<const WorkspaceReplica<Memory>&, tbc::lt::a> workspaces, const Agent<Memory>& agent) noexcept;
  template tbc::view<const Worktree<ConcurrentMemory>*, tbc::lt::a> AgentOrder::taskRow<ConcurrentMemory>(tbc::view<const WorkspaceReplica<ConcurrentMemory>&, tbc::lt::a> workspaces, const Agent<ConcurrentMemory>& agent) noexcept;
  template AgentOrder::Priority AgentOrder::priority<Memory>(const Agent<Memory>& agent) noexcept;
  template AgentOrder::Priority AgentOrder::priority<ConcurrentMemory>(const Agent<ConcurrentMemory>& agent) noexcept;
  template AgentOrder::Plan AgentOrder::arrange<Memory>(std::span<const Agent<Memory>> agents, const WorkspaceReplica<Memory>& workspaces) noexcept;
  template AgentOrder::Plan AgentOrder::arrange<ConcurrentMemory>(std::span<const Agent<ConcurrentMemory>> agents, const WorkspaceReplica<ConcurrentMemory>& workspaces) noexcept;
  template class ActivityOrder<Memory>;
  template class ActivityOrder<ConcurrentMemory>;

}
