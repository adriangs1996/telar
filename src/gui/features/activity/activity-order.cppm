// The order agent and task cards take: by attention, project and age, and as the forest of the
// agents that started others across the machines a window shows.
export module telar.gui.features.activity:order;

import std;

import :mark;
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
      static constexpr std::size_t unknown_project = std::numeric_limits<std::size_t>::max();

      enum class Attention : std::uint8_t {
        needs_input,
        working,
        done,
        ready,
        unknown,
      };

      struct Entry {
        std::size_t agent = 0;
        ds::Option<std::uint64_t> project = ds::none;
        ds::Option<std::size_t> creator = ds::none;
        ActivityCard card = ActivityCard::agent;
        bool first_in_project = false;
      };

      // What arrange sorts agents by: attention first, then age and pane.
      using Priority = std::tuple<Attention, std::uint32_t, std::uint64_t, std::uint64_t>;

      struct Plan {
        ds::Array<Entry, maximum_agents> entries{};
        std::size_t count = 0;

        [[nodiscard]] std::span<const Entry> view() const noexcept;
      };

      [[nodiscard]] static Attention attention(AgentStatus status) noexcept;

      // An agent that works or waits on the person: what a stack of agent cards shows.
      [[nodiscard]] static bool stacked(AgentStatus status) noexcept;

      template <Allocator Memory>
      // The row is one of the replica's, region `a`; the agent only names it.
      [[nodiscard]] static tbc::val_a<const Worktree<Memory>*> taskRow(tbc::ref_a<WorkspaceReplica<Memory>> workspaces, const Agent<Memory>& agent) noexcept;

      template <Allocator Memory>
      [[nodiscard]] static Priority priority(const Agent<Memory>& agent) noexcept;

      template <Allocator Memory>
      [[nodiscard]] static Plan arrange(std::span<const Agent<Memory>> agents, const WorkspaceReplica<Memory>& workspaces) noexcept;

    private:
      template <Allocator Memory>
      [[nodiscard]] static std::size_t projectRank(ds::Option<std::uint64_t> identity, std::span<const Workspace<Memory>> workspaces) noexcept;

      template <Allocator Memory>
      [[nodiscard]] static ds::Option<std::uint64_t> projectOf(const WorkspaceReplica<Memory>& workspaces, const Agent<Memory>& agent) noexcept;

      template <Allocator Memory>
      [[nodiscard]] static ds::Option<std::size_t> creatorOf(std::span<const Agent<Memory>> agents, const WorkspaceReplica<Memory>& workspaces, std::span<const Entry> entries, const Entry& entry) noexcept;

      template <Allocator Memory>
      [[nodiscard]] static bool lessThan(std::span<const Agent<Memory>> agents, const WorkspaceReplica<Memory>& workspaces, const Entry& left, const Entry& right) noexcept;
    };

    extern template tbc::val_a<const Worktree<Memory>*> AgentOrder::taskRow<Memory>(tbc::ref_a<WorkspaceReplica<Memory>> workspaces, const Agent<Memory>& agent) noexcept;
    extern template tbc::val_a<const Worktree<ConcurrentMemory>*> AgentOrder::taskRow<ConcurrentMemory>(tbc::ref_a<WorkspaceReplica<ConcurrentMemory>> workspaces, const Agent<ConcurrentMemory>& agent) noexcept;
    extern template AgentOrder::Priority AgentOrder::priority<Memory>(const Agent<Memory>& agent) noexcept;
    extern template AgentOrder::Priority AgentOrder::priority<ConcurrentMemory>(const Agent<ConcurrentMemory>& agent) noexcept;
    extern template AgentOrder::Plan AgentOrder::arrange<Memory>(std::span<const Agent<Memory>> agents, const WorkspaceReplica<Memory>& workspaces) noexcept;
    extern template AgentOrder::Plan AgentOrder::arrange<ConcurrentMemory>(std::span<const Agent<ConcurrentMemory>> agents, const WorkspaceReplica<ConcurrentMemory>& workspaces) noexcept;

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
        ds::Option<std::size_t> worktree = ds::none;
        ds::Option<std::uint64_t> project = ds::none;
        ActivityCard card = ActivityCard::agent;
        ds::Option<std::size_t> parent = ds::none;
        std::size_t depth = 0;
        bool coordinator = false;
        bool first_in_project = false;
      };

      struct Plan {
        ds::Array<Entry, maximum_entries> entries;
        std::size_t count = 0;

        [[nodiscard]] std::span<const Entry> view() const noexcept;
      };

      static void write(std::span<const Source> sources, std::uint8_t active_slot, Plan& output);

    private:
      enum class Visit : std::uint8_t {
        unseen,
        visiting,
        finished,
      };

      explicit ActivityOrder(std::span<const Source> sources, Plan& output);

      void collect(std::uint8_t active_slot);

      [[nodiscard]] auto identityAt(std::size_t index) const noexcept;

      [[nodiscard]] const Worktree<Memory>* rowOf(const Entry& entry) const noexcept;

      [[nodiscard]] ds::Option<std::size_t> parentOf(std::span<const std::size_t> agents, std::size_t index) const noexcept;

      void findParents();

      void breakChainCycle(std::size_t start, std::span<Visit> visits, std::span<std::size_t> path) noexcept;

      void breakCycles() noexcept;

      struct Children {
        ds::Array<ds::Option<std::size_t>, maximum_entries> first;
        ds::Array<ds::Option<std::size_t>, maximum_entries> last;
        ds::Array<ds::Option<std::size_t>, maximum_entries> next;
      };

      [[nodiscard]] Children linkChildren() noexcept;

      void emitForest() noexcept;

      std::span<const Source> sources_;
      Plan& output_;
      ds::Array<Entry, maximum_entries> nodes_;
      std::size_t count_ = 0;
    };

    extern template class ActivityOrder<Memory>;
    extern template class ActivityOrder<ConcurrentMemory>;

  }
}
