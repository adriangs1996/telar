// The order agent and task cards take: one inbox across the machines a window shows, by
// attention, then by how recently each card changed.
export module telar.gui.features.activity:order;

import std;

import telar.tbc;
import telar.base.memory.allocators;
import telar.wire.vocabulary;
import telar.gui.foundation.core;
import telar.gui.foundation.model;
import telar.base.ds;

// Interface: presentation/agent_order.cppm
export {
  namespace telar::gui::features::activity {

    struct AgentOrder {
      static constexpr std::size_t maximum_agents = 64;

      enum class Attention : std::uint8_t {
        needs_input,
        working,
        done,
        ready,
        unknown,
      };

      // What agents sort by: attention first, then the newest status change on the window's
      // clock, then the age the runtime reported, then the pane.
      using Priority = std::tuple<Attention, std::int64_t, std::uint32_t, std::uint64_t, std::uint64_t>;

      [[nodiscard]] static Attention attention(AgentStatus status) noexcept;

      // An agent that works or waits on the person: what a stack of agent cards shows.
      [[nodiscard]] static bool stacked(AgentStatus status) noexcept;

      template <Allocator Memory>
      // The row is one of the replica's, region `a`; the agent only names it.
      [[nodiscard]] static tbc::val_a<const Worktree<Memory>*> taskRow(tbc::ref_a<WorkspaceReplica<Memory>> workspaces, const Agent<Memory>& agent) noexcept;

      template <Allocator Memory>
      [[nodiscard]] static Priority priority(const Agent<Memory>& agent) noexcept;
    };

    extern template tbc::val_a<const Worktree<Memory>*> AgentOrder::taskRow<Memory>(tbc::ref_a<WorkspaceReplica<Memory>> workspaces, const Agent<Memory>& agent) noexcept;
    extern template tbc::val_a<const Worktree<ConcurrentMemory>*> AgentOrder::taskRow<ConcurrentMemory>(tbc::ref_a<WorkspaceReplica<ConcurrentMemory>> workspaces, const Agent<ConcurrentMemory>& agent) noexcept;
    extern template AgentOrder::Priority AgentOrder::priority<Memory>(const Agent<Memory>& agent) noexcept;
    extern template AgentOrder::Priority AgentOrder::priority<ConcurrentMemory>(const Agent<ConcurrentMemory>& agent) noexcept;

  }
}

// Interface: presentation/activity_order.cppm
export {
  namespace telar::gui::features::activity {

    template <Allocator Memory>
    class ActivityOrder {
    public:
      static constexpr std::size_t maximum_sources = 17;
      static constexpr std::size_t maximum_entries = maximum_sources * (AgentOrder::maximum_agents + WorkspaceReplica<Memory>::maximum_worktrees);

      struct Source {
        std::uint8_t slot = 0;
        std::span<const Agent<Memory>> agents;
        const WorkspaceReplica<Memory>& workspaces;
      };

      struct Entry {
        std::size_t source = 0;
        ds::Option<std::size_t> agent = ds::none;
        // The task's row: set for an agent in a worktree and for a tracked command.
        ds::Option<std::size_t> worktree = ds::none;
        ds::Option<std::uint64_t> project = ds::none;
        // Another card's worktree names this agent as its coordinator or creator.
        bool coordinator = false;
      };

      struct Plan {
        ds::Array<Entry, maximum_entries> entries;
        std::size_t count = 0;

        [[nodiscard]] std::span<const Entry> view() const noexcept;
      };

      static void write(std::span<const Source> sources, std::uint8_t active_slot, Plan& output);

    private:
      // What the inbox sorts by: the agent's priority, or a command's attention as the oldest of
      // its group; then commands after agents, then the source and the card's identity.
      using Rank = std::tuple<AgentOrder::Attention, std::int64_t, std::uint32_t, bool, std::size_t, std::uint64_t, std::uint64_t>;

      explicit ActivityOrder(std::span<const Source> sources, Plan& output);

      void collect(std::uint8_t active_slot);

      [[nodiscard]] static ds::Option<std::uint64_t> projectOf(const WorkspaceReplica<Memory>& workspaces, const Agent<Memory>& agent) noexcept;

      [[nodiscard]] auto identityAt(std::size_t index) const noexcept;

      [[nodiscard]] const Worktree<Memory>* rowOf(const Entry& entry) const noexcept;

      [[nodiscard]] ds::Option<std::size_t> coordinatorOf(std::span<const std::size_t> agents, std::size_t index) const noexcept;

      void markCoordinators() noexcept;

      [[nodiscard]] Rank rank(const Entry& entry) const noexcept;

      void sort() noexcept;

      std::span<const Source> sources_;
      Plan& output_;
    };

    extern template class ActivityOrder<Memory>;
    extern template class ActivityOrder<ConcurrentMemory>;

  }
}
