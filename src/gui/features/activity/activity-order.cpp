module telar.gui.features.activity;

import std;
import telar.tbc;
import telar.gui.foundation.core;
import telar.gui.foundation.model;
import telar.base.ds;

namespace telar::gui::features::activity {

  namespace {

    constexpr auto clock_limit = static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max());

    // A tracked command waits on the person once it fails, and is done once it succeeds.
    template <Allocator Memory>
    AgentOrder::Attention commandAttention(const Worktree<Memory>& row) noexcept {
      switch (row.command_state) {
      case CommandState::running:
        return AgentOrder::Attention::working;
      case CommandState::exited:
        return row.command_exit == 0 ? AgentOrder::Attention::done : AgentOrder::Attention::needs_input;
      case CommandState::none:
        break;
      }

      return AgentOrder::Attention::unknown;
    }

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
    case AgentStatus::unknown:
      break;
    }

    // An unknown agent, or a status outside the enum.
    return Attention::unknown;
  }

  bool AgentOrder::stacked(AgentStatus status) noexcept {
    const auto group = attention(status);

    return group == Attention::needs_input || group == Attention::working;
  }

  template <Allocator Memory>
  tbc::val_a<const Worktree<Memory>*> AgentOrder::taskRow(tbc::ref_a<WorkspaceReplica<Memory>> workspaces, const Agent<Memory>& agent) noexcept {
    if (const auto* row = workspaces.worktree(agent.work_tree)) {
      return row;
    }

    return agent.location.workspace.kind == WorkspaceLocation::Kind::workspace ? workspaces.worktreeOfWorkspace(agent.location.workspace.id) : nullptr;
  }

  // Each machine's snapshot reports its ages when it was encoded; the window's clock sampled
  // each one, so `age - sampled` orders status changes across machines. The smaller, the newer.
  template <Allocator Memory>
  auto AgentOrder::priority(const Agent<Memory>& agent) noexcept -> Priority {
    const auto interval = agent.status_clock.interval();
    const auto age = static_cast<std::int64_t>(std::min(interval.age_ns, clock_limit));
    const auto sampled = static_cast<std::int64_t>(std::min(interval.sampled_ns, clock_limit));

    return std::tuple{attention(agent.status), age - sampled, agent.status_age_s, agent.pane_id, agent.pane_generation};
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
    order.markCoordinators();
    order.sort();
  }

  template <Allocator Memory>
  ActivityOrder<Memory>::ActivityOrder(std::span<const Source> sources, Plan& output)
      : sources_(sources),
        output_(output) {}

  template <Allocator Memory>
  void ActivityOrder<Memory>::collect(std::uint8_t active_slot) {
    output_.count = 0;
    for (std::size_t source_index = 0; source_index < sources_.size(); ++source_index) {
      const auto& source = sources_[source_index];
      if (source.agents.size() > AgentOrder::maximum_agents) {
        throw std::length_error{"TooManyAgents"};
      }

      // Another machine's row in the sidebar stacks its working agents, so its cards here are
      // only the agents that wait on the person; its tracked commands stay on that machine.
      const bool active = source.slot == active_slot;
      const auto& worktrees = source.workspaces.worktrees();
      ds::Array<bool, WorkspaceReplica<Memory>::maximum_worktrees> represented{};

      for (std::size_t index = 0; index < source.agents.size(); ++index) {
        const auto& agent = source.agents[index];
        if (!active && AgentOrder::attention(agent.status) != AgentOrder::Attention::needs_input) {
          continue;
        }

        const auto* row = AgentOrder::taskRow(source.workspaces, agent);
        auto& entry = output_.entries.atMut(output_.count++);

        entry = {.source = source_index, .agent = index, .project = projectOf(source.workspaces, agent)};
        if (row != nullptr) {
          const auto row_index = static_cast<std::size_t>(row - worktrees.data());

          entry.worktree = row_index;
          represented.atMut(row_index) = true;
        }
      }

      for (std::size_t index = 0; index < worktrees.size() && active; ++index) {
        const auto& row = worktrees[index];
        if (!represented[index] && row.command_state != CommandState::none) {
          output_.entries.atMut(output_.count++) = {.source = source_index, .worktree = index, .project = row.source};
        }
      }
    }
  }

  template <Allocator Memory>
  ds::Option<std::uint64_t> ActivityOrder<Memory>::projectOf(const WorkspaceReplica<Memory>& workspaces, const Agent<Memory>& agent) noexcept {
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
  auto ActivityOrder<Memory>::identityAt(std::size_t index) const noexcept {
    const auto& entry = output_.entries[index];
    if (!entry.agent) {
      std::terminate();
    }

    const auto& agent = sources_[entry.source].agents[*entry.agent];

    return std::tuple{agent.session_id, agent.pane_id, agent.pane_generation};
  }

  template <Allocator Memory>
  const Worktree<Memory>* ActivityOrder<Memory>::rowOf(const Entry& entry) const noexcept {
    const auto& source = sources_[entry.source];

    return entry.worktree ? &source.workspaces.worktrees()[*entry.worktree] : nullptr;
  }

  // The card that coordinates the one at `index`: the exact agent its worktree's coordinator
  // reference names on any machine, else the agent card of its creator's pane on its own.
  template <Allocator Memory>
  ds::Option<std::size_t> ActivityOrder<Memory>::coordinatorOf(std::span<const std::size_t> agents, std::size_t index) const noexcept {
    const auto& entry = output_.entries[index];
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

    while (start != 0 && output_.entries[start - 1].source == entry.source) {
      --start;
    }

    for (std::size_t parent = start; parent < output_.count && output_.entries[parent].source == entry.source; ++parent) {
      const auto& candidate = output_.entries[parent];
      if (candidate.agent && !candidate.worktree && parent != index && candidate.project == entry.project && sources_[entry.source].agents[*candidate.agent].pane_id == *row->created_by) {
        return parent;
      }
    }

    return ds::none;
  }

  // Runs before the sort, while each source's cards are still contiguous.
  template <Allocator Memory>
  void ActivityOrder<Memory>::markCoordinators() noexcept {
    ds::Array<std::size_t, maximum_entries> agents{};
    std::size_t agent_count = 0;

    for (std::size_t index = 0; index < output_.count; ++index) {
      if (output_.entries[index].agent) {
        agents.atMut(agent_count++) = index;
      }
    }

    const auto indices = agents.viewMut().first(agent_count);

    std::ranges::sort(indices, [this](std::size_t left, std::size_t right) {
      return std::tuple{identityAt(left), left} < std::tuple{identityAt(right), right};
    });

    for (std::size_t index = 0; index < output_.count; ++index) {
      if (const auto coordinator = coordinatorOf(indices, index)) {
        output_.entries.atMut(*coordinator).coordinator = true;
      }
    }
  }

  template <Allocator Memory>
  auto ActivityOrder<Memory>::rank(const Entry& entry) const noexcept -> Rank {
    const auto& source = sources_[entry.source];

    if (entry.agent) {
      const auto [attention, changed, age, pane, generation] = AgentOrder::priority(source.agents[*entry.agent]);

      return Rank{attention, changed, age, false, entry.source, pane, generation};
    }

    const auto& row = source.workspaces.worktrees()[*entry.worktree];

    return Rank{commandAttention(row), std::numeric_limits<std::int64_t>::max(), std::numeric_limits<std::uint32_t>::max(), true, entry.source, row.id, 0};
  }

  template <Allocator Memory>
  void ActivityOrder<Memory>::sort() noexcept {
    std::ranges::sort(output_.entries.viewMut().first(output_.count), [this](const Entry& left, const Entry& right) {
      return rank(left) < rank(right);
    });
  }

  template tbc::val_a<const Worktree<Memory>*> AgentOrder::taskRow<Memory>(tbc::ref_a<WorkspaceReplica<Memory>> workspaces, const Agent<Memory>& agent) noexcept;
  template tbc::val_a<const Worktree<ConcurrentMemory>*> AgentOrder::taskRow<ConcurrentMemory>(tbc::ref_a<WorkspaceReplica<ConcurrentMemory>> workspaces, const Agent<ConcurrentMemory>& agent) noexcept;
  template AgentOrder::Priority AgentOrder::priority<Memory>(const Agent<Memory>& agent) noexcept;
  template AgentOrder::Priority AgentOrder::priority<ConcurrentMemory>(const Agent<ConcurrentMemory>& agent) noexcept;
  template class ActivityOrder<Memory>;
  template class ActivityOrder<ConcurrentMemory>;

}
