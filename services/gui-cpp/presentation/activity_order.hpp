#pragma once

#include "agent_order.hpp"
#include "application/records.hpp"
#include "application/workspace_replica.hpp"
#include "core/memory.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <array>
#include <compare>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <optional>
#include <span>
#include <stdexcept>
#include <tuple>

namespace telar::gui {

template <Allocator Memory>
class ActivityOrder {
public:
  static constexpr std::size_t maximum_sources = 17;
  static constexpr std::size_t maximum_entries = maximum_sources * (AgentOrder::maximum_agents + WorkspaceReplica<Memory>::maximum_worktrees);

  struct Source {
    std::uint8_t slot = 0;
    std::span<const Agent<Memory>> agents;
    const WorkspaceReplica<Memory> &workspaces;
    std::optional<std::uint64_t> focused = std::nullopt;
  };

  struct Entry {
    std::size_t source = 0;
    std::optional<std::size_t> agent = std::nullopt;
    std::optional<std::size_t> worktree = std::nullopt;
    std::optional<std::uint64_t> project = std::nullopt;
    ActivityCard card = ActivityCard::agent;
    std::optional<std::size_t> parent = std::nullopt;
    std::size_t depth = 0;
    bool coordinator = false;
    bool first_in_project = false;
  };

  struct Plan {
    std::array<Entry, maximum_entries> entries;
    std::size_t count = 0;

    [[nodiscard]] std::span<const Entry> view() const noexcept {
      return std::span{entries}.first(count);
    }
  };

  static void write(std::span<const Source> sources, std::uint8_t active_slot, Plan &output) {
    if (sources.size() > maximum_sources) {
      throw std::length_error{"TooManyActivitySources"};
    }

    ActivityOrder order{sources, output};
    order.collect(active_slot);
    order.findParents();
    order.breakCycles();
    order.emitForest();
  }

private:
  enum class Visit : std::uint8_t {
    unseen,
    visiting,
    finished,
  };

  explicit ActivityOrder(std::span<const Source> sources, Plan &output)
      : sources_(sources),
        output_(output) {}

  void collect(std::uint8_t active_slot) {
    for (std::size_t source_index = 0; source_index < sources_.size(); ++source_index) {
      const auto &source = sources_[source_index];
      if (source.agents.size() > AgentOrder::maximum_agents) {
        throw std::length_error{"TooManyAgents"};
      }

      const auto fleet = AgentOrder::arrange(source.agents, source.workspaces, source.slot == active_slot ? source.focused : std::nullopt);
      const auto &worktrees = source.workspaces.worktrees();
      std::array<bool, WorkspaceReplica<Memory>::maximum_worktrees> represented{};
      for (const auto &entry : fleet.view()) {
        auto &node = nodes_[count_++];
        node = {.source = source_index, .agent = entry.agent, .project = entry.project, .card = entry.card};
        if (const auto *row = AgentOrder::taskRow(source.workspaces, source.agents[entry.agent])) {
          const auto index = static_cast<std::size_t>(row - worktrees.data());
          node.worktree = index;
          represented[index] = true;
        }
      }

      for (std::size_t index = 0; index < worktrees.size(); ++index) {
        const auto &row = worktrees[index];
        if (!represented[index] && row.command_state != CommandState::none) {
          nodes_[count_++] = {.source = source_index, .worktree = index, .project = row.source, .card = ActivityCard::task_full};
        }
      }
    }
  }

  [[nodiscard]] auto identityAt(std::size_t index) const noexcept {
    const auto &node = nodes_[index];
    if (!node.agent) {
      std::terminate();
    }

    const auto &agent = sources_[node.source].agents[*node.agent];

    return std::tuple{agent.session_id, agent.pane_id, agent.pane_generation};
  }

  [[nodiscard]] const Worktree<Memory> *rowOf(const Entry &entry) const noexcept {
    const auto &source = sources_[entry.source];
    if (entry.worktree) {
      return &source.workspaces.worktrees()[*entry.worktree];
    }

    return entry.agent ? AgentOrder::taskRow(source.workspaces, source.agents[*entry.agent]) : nullptr;
  }

  [[nodiscard]] std::optional<std::size_t> parentOf(std::span<const std::size_t> agents, std::size_t index) const noexcept {
    const auto &entry = nodes_[index];
    const auto *row = rowOf(entry);
    if (row == nullptr) {
      return std::nullopt;
    }

    if (row->coordinator) {
      const auto &reference = *row->coordinator;
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

      return std::nullopt;
    }

    if (!row->created_by) {
      return std::nullopt;
    }

    std::size_t start = index;
    while (start != 0 && nodes_[start - 1].source == entry.source) {
      --start;
    }

    for (std::size_t parent = start; parent < count_ && nodes_[parent].source == entry.source; ++parent) {
      const auto &candidate = nodes_[parent];
      if (candidate.agent && parent != index && candidate.card == ActivityCard::agent && candidate.project == entry.project && sources_[entry.source].agents[*candidate.agent].pane_id == *row->created_by) {
        return parent;
      }
    }

    return std::nullopt;
  }

  void findParents() {
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

  void breakChainCycle(std::size_t start, std::span<Visit> visits, std::span<std::size_t> path) noexcept {
    std::size_t path_length = 0;
    std::optional<std::size_t> current{start};
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

  void breakCycles() noexcept {
    std::array<Visit, maximum_entries> visits{};
    std::array<std::size_t, maximum_entries> path{};
    for (std::size_t start = 0; start < count_; ++start) {
      if (visits[start] != Visit::finished) {
        breakChainCycle(start, visits, path);
      }
    }
  }

  struct Children {
    std::array<std::optional<std::size_t>, maximum_entries> first;
    std::array<std::optional<std::size_t>, maximum_entries> last;
    std::array<std::optional<std::size_t>, maximum_entries> next;
  };

  [[nodiscard]] Children linkChildren() noexcept {
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

  void emitForest() noexcept {
    const auto children = linkChildren();
    std::array<std::size_t, maximum_entries> positions{};
    std::optional<std::size_t> previous_source;
    std::optional<std::uint64_t> previous_project;
    output_.count = 0;
    for (std::size_t root_index = 0; root_index < count_; ++root_index) {
      const auto &root = nodes_[root_index];
      if (root.parent) {
        continue;
      }

      auto current = root_index;
      std::size_t depth = 0;
      while (true) {
        auto entry = nodes_[current];
        entry.depth = depth;
        entry.parent = entry.parent ? std::optional{positions[*entry.parent]} : std::nullopt;
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

  std::span<const Source> sources_;
  Plan &output_;
  std::array<Entry, maximum_entries> nodes_;
  std::size_t count_ = 0;
};

}
