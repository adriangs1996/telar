export module telar.gui.foundation.model:replicas;

import std;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.wire.agents;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import :records;
import telar.base.ds;

// Interface: application/agent_replica.cppm
export {
  namespace telar::gui::inline foundation::inline model {

    template <Allocator Memory>
    class AgentReplica {
    public:
      static constexpr std::size_t capacity = 64;

      explicit AgentReplica(Memory& memory);

      [[nodiscard]] const Vector<Agent<Memory>, Memory>& entries() const noexcept;
      [[nodiscard]] typename Vector<Agent<Memory>, Memory>::const_iterator begin() const noexcept;
      [[nodiscard]] typename Vector<Agent<Memory>, Memory>::const_iterator end() const noexcept;
      [[nodiscard]] std::uint64_t revision() const noexcept;
      [[nodiscard]] std::span<const AgentStatusChange> statusChanges() const noexcept;
      void resetSource() noexcept;
      bool apply(const AgentSnapshot& snapshot, std::uint64_t now_ns);

    private:
      static void validate(const AgentSnapshot& snapshot);
      void prepareStaging(std::size_t count);
      static void assign(Agent<Memory>& agent, const AgentSnapshotEntry& entry);

      Memory& memory_;
      Vector<Agent<Memory>, Memory> entries_;
      Vector<Agent<Memory>, Memory> staging_;
      ds::Array<AgentStatusChange, capacity> status_changes_;
      std::size_t status_change_count_ = 0;
      std::uint64_t revision_ = 0;
      std::uint64_t now_ns_ = 0;
      bool retain_clocks_ = false;
    };

    extern template class AgentReplica<Memory>;
    extern template class AgentReplica<ConcurrentMemory>;

  }
}

// Interface: application/pane_list_replica.cppm
export {
  namespace telar::gui::inline foundation::inline model {

    // A live pane of the runtime and the process holding its terminal.
    struct ListedPane {
      static constexpr std::size_t foreground_capacity = 48;

      std::uint64_t pane_id = 0;
      std::uint64_t pane_generation = 0;
      TabLocation location;
      runtime::FixedText<foreground_capacity> foreground;
      // How long the foreground process has held the terminal, as of its arrival.
      StatusAgeInterval age;
      ds::Array<std::uint16_t, max_listed_ports> port_values{};
      std::uint8_t port_count = 0;
      bool shell = false;

      [[nodiscard]] std::span<const std::uint16_t> ports() const noexcept;
    };

    // The runtime's pane list, replaced whole by each newer revision.
    template <Allocator Memory>
    class PaneListReplica {
    public:
      static constexpr std::size_t capacity = max_pane_list_entries;

      explicit PaneListReplica(Memory& memory);

      [[nodiscard]] std::span<const ListedPane> entries() const noexcept;
      [[nodiscard]] std::uint64_t revision() const noexcept;
      [[nodiscard]] const ListedPane* find(std::uint64_t pane_id, std::uint64_t generation) const noexcept;
      void resetSource() noexcept;
      bool apply(const PaneList& list, std::uint64_t now_ns);

    private:
      Vector<ListedPane, Memory> entries_;
      std::uint64_t revision_ = 0;
    };

    extern template class PaneListReplica<Memory>;
    extern template class PaneListReplica<ConcurrentMemory>;

  }
}

// Interface: application/workspace_replica.cppm
export {
  namespace telar::gui::inline foundation::inline model {

    template <Allocator Memory>
    class WorkspaceReplica {
    public:
      static constexpr std::size_t maximum_workspaces = 64;
      static constexpr std::size_t maximum_worktrees = 64;
      static constexpr std::size_t average_path_bytes = 512;
      static constexpr std::size_t path_pool_bytes = maximum_workspaces * average_path_bytes;

      explicit WorkspaceReplica(Memory& memory);

      [[nodiscard]] const Vector<Workspace<Memory>, Memory>& entries() const noexcept;
      [[nodiscard]] std::span<const Workspace<Memory>> projects() const noexcept;
      [[nodiscard]] const Vector<Worktree<Memory>, Memory>& worktrees() const noexcept;
      [[nodiscard]] std::span<Workspace<Memory>> entriesMut() noexcept;
      [[nodiscard]] typename Vector<Workspace<Memory>, Memory>::const_iterator begin() const noexcept;
      [[nodiscard]] typename Vector<Workspace<Memory>, Memory>::const_iterator end() const noexcept;
      [[nodiscard]] std::uint64_t revision() const noexcept;
      [[nodiscard]] std::size_t dropped() const noexcept;
      [[nodiscard]] const Worktree<Memory>* worktree(std::uint64_t identity) const noexcept;
      [[nodiscard]] const Worktree<Memory>* worktreeOfWorkspace(std::uint64_t identity) const noexcept;
      [[nodiscard]] std::size_t indexOf(std::uint64_t identity) const noexcept;
      [[nodiscard]] std::uint64_t projectOf(std::uint64_t workspace) const noexcept;
      void resetSource() noexcept;
      bool apply(const WorkspaceList& snapshot);

    private:
      static void validateCapacity(const WorkspaceList& snapshot);
      static bool holdsWorktree(const WorkspaceList& snapshot, std::uint64_t identity) noexcept;
      static std::size_t retainedCount(std::span<const WorkspaceListEntry* const> ordered);
      template <typename Row>
      static void prepare(Vector<Row, Memory>& rows, std::size_t count, Memory& memory);
      static void assign(Workspace<Memory>& row, const WorkspaceListEntry& entry);
      static void assign(Worktree<Memory>& row, const WorktreeListEntry& entry);

      Memory& memory_;
      Vector<Workspace<Memory>, Memory> entries_;
      Vector<Workspace<Memory>, Memory> staging_entries_;
      Vector<Worktree<Memory>, Memory> worktrees_;
      Vector<Worktree<Memory>, Memory> staging_worktrees_;
      std::uint64_t revision_ = 0;
      std::size_t project_count_ = 0;
      std::size_t dropped_ = 0;
    };

    extern template class WorkspaceReplica<Memory>;
    extern template class WorkspaceReplica<ConcurrentMemory>;

  }
}
