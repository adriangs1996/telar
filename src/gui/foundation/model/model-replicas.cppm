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

      [[nodiscard]] const ds::Vec<Agent<Memory>, Memory>& entries() const noexcept;
      [[nodiscard]] const Agent<Memory>* begin() const noexcept;
      [[nodiscard]] const Agent<Memory>* end() const noexcept;
      [[nodiscard]] std::uint64_t revision() const noexcept;
      [[nodiscard]] std::span<const AgentStatusChange> statusChanges() const noexcept;
      void resetSource() noexcept;
      bool apply(const AgentSnapshot& snapshot, std::uint64_t now_ns);

    private:
      static void validate(const AgentSnapshot& snapshot);
      void prepareStaging(std::size_t count);
      static void assign(Agent<Memory>& agent, const AgentSnapshotEntry& entry);

      Memory& memory_;
      ds::Vec<Agent<Memory>, Memory> entries_;
      ds::Vec<Agent<Memory>, Memory> staging_;
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

    // What the runtime's PaneFacts say of a listed pane: the command its integrated shell runs or
    // last ran, where the pane works and the repository there. As made until the first arrives,
    // and for every pane of a runtime older than the message.
    struct ListedPaneFacts {
      PaneCommandState command_state = PaneCommandState::none;
      bool command_truncated = false;
      bool in_workspace = false;
      bool dirty = false;
      // The status a finished command exited with, when its shell reported one.
      ds::Option<std::int32_t> exit_code;
      std::uint32_t duration_ms = 0;
      runtime::FixedText<max_pane_command_bytes> command;
      runtime::FixedText<max_pane_directory_bytes> directory;
      runtime::FixedText<max_pane_branch_bytes> branch;
      // The file an editor pane shows in its focused window; empty for every other pane.
      runtime::FixedText<max_pane_document_bytes> document;

      // Whether these are the facts `message` carries.
      [[nodiscard]] bool same(const PaneFacts& message) const noexcept;
    };

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
      ListedPaneFacts facts;

      [[nodiscard]] std::span<const std::uint16_t> ports() const noexcept;
    };

    // The runtime's pane list, replaced whole by each newer revision. A pane a newer list still
    // names keeps the facts it had.
    template <Allocator Memory>
    class PaneListReplica {
    public:
      static constexpr std::size_t capacity = max_pane_list_entries;

      explicit PaneListReplica(Memory& memory);

      [[nodiscard]] std::span<const ListedPane> entries() const noexcept;
      [[nodiscard]] std::uint64_t revision() const noexcept;
      // Counts the facts the list took, for what shows them.
      [[nodiscard]] std::uint64_t factsRevision() const noexcept;
      [[nodiscard]] const ListedPane* find(std::uint64_t pane_id, std::uint64_t generation) const noexcept;
      void resetSource() noexcept;
      bool apply(const PaneList& list, std::uint64_t now_ns);
      // False when the list names no such pane, or it has these facts already.
      bool apply(const PaneFacts& facts);

    private:
      ds::Vec<ListedPane, Memory> entries_;
      // The list being built, so the one shown stays whole until it is.
      ds::Vec<ListedPane, Memory> staging_;
      std::uint64_t revision_ = 0;
      std::uint64_t facts_revision_ = 0;
      // The next list comes from the runtime that sent the one shown.
      bool inherits_ = false;
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

      [[nodiscard]] const ds::Vec<Workspace<Memory>, Memory>& entries() const noexcept;
      [[nodiscard]] std::span<const Workspace<Memory>> projects() const noexcept;
      [[nodiscard]] const ds::Vec<Worktree<Memory>, Memory>& worktrees() const noexcept;
      [[nodiscard]] std::span<Workspace<Memory>> entriesMut() noexcept;
      [[nodiscard]] const Workspace<Memory>* begin() const noexcept;
      [[nodiscard]] const Workspace<Memory>* end() const noexcept;
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
      static void prepare(ds::Vec<Row, Memory>& rows, std::size_t count, Memory& memory);
      static void assign(Workspace<Memory>& row, const WorkspaceListEntry& entry);
      static void assign(Worktree<Memory>& row, const WorktreeListEntry& entry);

      Memory& memory_;
      ds::Vec<Workspace<Memory>, Memory> entries_;
      ds::Vec<Workspace<Memory>, Memory> staging_entries_;
      ds::Vec<Worktree<Memory>, Memory> worktrees_;
      ds::Vec<Worktree<Memory>, Memory> staging_worktrees_;
      std::uint64_t revision_ = 0;
      std::size_t project_count_ = 0;
      std::size_t dropped_ = 0;
    };

    extern template class WorkspaceReplica<Memory>;
    extern template class WorkspaceReplica<ConcurrentMemory>;

  }
}
