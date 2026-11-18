module;
#include "tbc/annotations.hpp"

export module telar.gui.foundation.model:records;

import std;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.wire.vocabulary;
import :pane_layout;
import telar.base.ds;

// Interface: presentation/status_age.cppm
export {
  namespace telar::gui::inline foundation::inline model {

    struct StatusAgeInterval {
      static constexpr std::uint64_t nanoseconds_per_second = 1'000'000'000;
      std::uint64_t age_ns = 0;
      std::uint64_t sampled_ns = 0;

      [[nodiscard]] std::uint64_t elapsed(std::uint64_t now_ns) const noexcept;
      [[nodiscard]] std::uint32_t seconds(std::uint64_t now_ns) const noexcept;

      bool operator==(const StatusAgeInterval&) const = default;
    };

    struct StatusAgeSample {
      std::uint64_t pane_id = 0;
      std::uint64_t pane_generation = 0;
      AgentStatus status = AgentStatus::unknown;
      AgentProvider provider = AgentProvider::unknown;
      std::uint32_t reported_seconds = 0;

      [[nodiscard]] bool continues(const StatusAgeSample& previous) const noexcept;
    };

    class StatusAge {
    public:
      void observe(StatusAgeSample sample, std::uint64_t now_ns) noexcept;
      [[nodiscard]] bool observed() const noexcept;
      [[nodiscard]] StatusAgeInterval interval() const noexcept;

    private:
      StatusAgeSample sample_;
      StatusAgeInterval interval_;
    };

  }
}

// Interface: application/agent_status_change.cppm
export {
  namespace telar::gui::inline foundation::inline model {

    struct AgentStatusChange {
      std::uint64_t pane_id = 0;
      std::uint64_t pane_generation = 0;
      std::uint16_t pane_index = 0;
      AgentProvider provider = AgentProvider::unknown;
      AgentStatus previous = AgentStatus::unknown;
      AgentStatus current = AgentStatus::unknown;
    };

  }
}

// Interface: application/records.cppm
export {
  namespace telar::gui::inline foundation::inline model {

    // A pane the runtime listed for a tab. It stands in for the pane while the tab is not loaded.
    struct TabMember {
      static constexpr std::size_t foreground_capacity = 48;

      std::uint64_t pane_id = 0;
      runtime::FixedText<foreground_capacity> foreground;
    };

    template <Allocator Memory>
    struct Tab {
      explicit Tab(Memory& memory, TabLocation identity);

      void observeForeground(PaneForeground report);
      // The tab shows its focused pane, else the first one the runtime listed.
      void observePanes(std::span<const TabPane> panes);

      TabLocation location;
      String<Memory> label;
      String<Memory> foreground;
      // The foreground pane's working directory, as the runtime last listed it.
      String<Memory> directory;
      Vector<TabMember, Memory> members;
      PaneLayout layout;
      std::uint64_t focused_pane = 0;
      std::uint64_t foreground_pane = 0;
      std::uint16_t position = 0;
      bool fullscreen = false;
      bool loaded = false;
      bool loading = false;
      bool workspace_active = false;
    };

    extern template struct Tab<Memory>;
    extern template struct Tab<ConcurrentMemory>;

    template <Allocator Memory>
    struct Workspace {
      explicit Workspace(Memory& memory, WorkspaceLocation identity = {});

      WorkspaceLocation location;
      String<Memory> name;
      String<Memory> path;
      String<Memory> branch;
      bool dirty = false;
      std::uint16_t tab_count = 0;
    };

    extern template struct Workspace<Memory>;
    extern template struct Workspace<ConcurrentMemory>;

    template <Allocator Memory>
    struct Worktree {
      static constexpr std::size_t retained_path_bytes = 256;

      explicit Worktree(Memory& memory);

      [[nodiscard]] std::string_view displayName() const noexcept;
      [[nodiscard]] std::string_view handle() const noexcept;

      std::uint64_t id = 0;
      std::uint64_t source = 0;
      ds::Option<std::uint64_t> workspace;
      ds::Option<std::uint64_t> created_by;
      ds::Option<CoordinatorReference> coordinator;
      WorktreeState state = WorktreeState::active;
      String<Memory> path;
      String<Memory> branch;
      String<Memory> base;
      String<Memory> title;
      String<Memory> command_label;
      std::uint32_t diff_added = 0;
      std::uint32_t diff_removed = 0;
      std::uint32_t diff_files = 0;
      std::uint32_t commits_ahead = 0;
      CommandState command_state = CommandState::none;
      std::int32_t command_exit = 0;
    };

    extern template struct Worktree<Memory>;
    extern template struct Worktree<ConcurrentMemory>;

    template <Allocator Memory>
    struct Agent {
      explicit Agent(Memory& memory);

      [[nodiscard]] std::string_view finalLine() const noexcept;

      std::uint64_t pane_id = 0;
      std::uint64_t pane_generation = 0;
      std::uint16_t pane_index = 0;
      decltype(AgentSnapshotEntry::session_id) session_id{};
      std::uint64_t work_tree = 0;
      TabLocation location;
      AgentStatus status{};
      AgentBlockedReason blocked_reason = AgentBlockedReason::none;
      AgentProvider provider_kind = AgentProvider::unknown;
      AgentAttachmentMarkers attachments = AgentAttachmentMarkers::none;
      AgentTitleState title_state = AgentTitleState::placeholder;
      String<Memory> title;
      String<Memory> provider_name;
      String<Memory> workspace_label;
      String<Memory> display_name;
      String<Memory> icon;
      String<Memory> detail;
      String<Memory> plan_step;
      String<Memory> final_message;
      std::uint16_t plan_done = 0;
      std::uint16_t plan_total = 0;
      std::uint32_t status_age_s = 0;
      StatusAge status_clock;
    };

    extern template struct Agent<Memory>;
    extern template struct Agent<ConcurrentMemory>;

  }
}

// Interface: model/tab_leaves.cppm
export {
  namespace telar::gui::inline foundation::inline model {

    // Calls `visit` with each pane leaf of `tab` in layout order; with `shown`, only the leaves the
    // tab shows: the focused one alone when it is fullscreen.
    template <Allocator Memory, typename Visit>
    TBC_GENERIC void forEachLeaf(const Tab<Memory>& tab, bool shown, Visit&& visit) {
      for (const auto& node : tab.layout.nodes()) {
        const auto* leaf = std::get_if<ClientLayoutPane>(&node);
        if (leaf != nullptr && (!shown || !tab.fullscreen || leaf->pane_id == tab.focused_pane)) {
          visit(*leaf);
        }
      }
    }

  }
}
