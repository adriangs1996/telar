module;
#include "tbc/view.hpp"

export module telar.gui.model.records;

import std;

export import telar.gui.layout.geometry;
import telar.base.diagnostics;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.wire.agents;
import telar.wire.layout;
import telar.wire.vocabulary;

// Interface: presentation/status_age.cppm
export {
  namespace telar::gui {

    struct StatusAgeInterval {
      static constexpr std::uint64_t nanoseconds_per_second = 1'000'000'000;
      std::uint64_t age_ns = 0;
      std::uint64_t sampled_ns = 0;

      [[nodiscard]] inline std::uint64_t elapsed(std::uint64_t now_ns) const noexcept {
        const auto delta = now_ns > sampled_ns ? now_ns - sampled_ns : 0;

        return age_ns + std::min(std::numeric_limits<std::uint64_t>::max() - age_ns, delta);
      }

      [[nodiscard]] inline std::uint32_t seconds(std::uint64_t now_ns) const noexcept {
        return static_cast<std::uint32_t>(std::min<std::uint64_t>(std::numeric_limits<std::uint32_t>::max(), elapsed(now_ns) / nanoseconds_per_second));
      }

      bool operator==(const StatusAgeInterval&) const = default;
    };

    struct StatusAgeSample {
      std::uint64_t pane_id = 0;
      std::uint64_t pane_generation = 0;
      AgentStatus status = AgentStatus::unknown;
      AgentProvider provider = AgentProvider::unknown;
      std::uint32_t reported_seconds = 0;

      [[nodiscard]] inline bool continues(const StatusAgeSample& previous) const noexcept {
        return pane_id == previous.pane_id && pane_generation == previous.pane_generation && status == previous.status && provider == previous.provider && reported_seconds >= previous.reported_seconds;
      }
    };

    class StatusAge {
    public:
      inline void observe(StatusAgeSample sample, std::uint64_t now_ns) noexcept {
        auto age_ns = static_cast<std::uint64_t>(sample.reported_seconds) * StatusAgeInterval::nanoseconds_per_second;

        if (sample.continues(sample_)) {
          age_ns = std::max(age_ns, interval_.elapsed(now_ns));
        }

        sample_ = sample;
        interval_ = {.age_ns = age_ns, .sampled_ns = now_ns};
      }

      [[nodiscard]] inline bool observed() const noexcept {
        return sample_.pane_id != 0;
      }

      [[nodiscard]] inline StatusAgeInterval interval() const noexcept {
        return interval_;
      }

    private:
      StatusAgeSample sample_;
      StatusAgeInterval interval_;
    };

  }
}

// Interface: application/agent_status_change.cppm
export {
  namespace telar::gui {

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
  namespace telar::gui {

    // A pane the runtime listed for a tab. It stands in for the pane while the tab is not loaded.
    struct TabMember {
      static constexpr std::size_t foreground_capacity = 48;

      std::uint64_t pane_id = 0;
      runtime::FixedText<foreground_capacity> foreground;
    };

    template <Allocator Memory>
    struct Tab {
      inline explicit Tab(Memory& memory, TabLocation identity)
          : location(identity),
            label(AllocatorRef<char, Memory>{memory}),
            foreground(AllocatorRef<char, Memory>{memory}),
            directory(AllocatorRef<char, Memory>{memory}),
            members(AllocatorRef<TabMember, Memory>{memory}) {}

      inline void observeForeground(PaneForeground report) {
        if (foreground_pane == report.pane_id) {
          foreground = report.name;
        }

        for (auto& member : members) {
          if (member.pane_id == report.pane_id) {
            member.foreground.assign(report.name);
          }
        }
      }

      // The tab shows its focused pane, else the first one the runtime listed.
      inline void observePanes(std::span<const TabPane> panes) {
        members.clear();
        if (panes.empty()) {
          return;
        }

        members.reserve(panes.size());
        const auto* selected = &panes.front();

        for (const auto& pane : panes) {
          auto& member = members.emplace_back();

          member.pane_id = pane.pane_id;
          member.foreground.assign(pane.foreground);
          if (pane.pane_id == focused_pane) {
            selected = &pane;
          }
        }

        foreground = selected->foreground;
        foreground_pane = selected->pane_id;
        directory = selected->cwd;
      }

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

    template <Allocator Memory>
    struct Workspace {
      inline explicit Workspace(Memory& memory, WorkspaceLocation identity = {})
          : location(identity),
            name(AllocatorRef<char, Memory>{memory}),
            path(AllocatorRef<char, Memory>{memory}),
            branch(AllocatorRef<char, Memory>{memory}) {}

      WorkspaceLocation location;
      String<Memory> name;
      String<Memory> path;
      String<Memory> branch;
      bool dirty = false;
      std::uint16_t tab_count = 0;
    };

    template <Allocator Memory>
    struct Worktree {
      static constexpr std::size_t retained_path_bytes = 256;

      inline explicit Worktree(Memory& memory)
          : path(AllocatorRef<char, Memory>{memory}),
            branch(AllocatorRef<char, Memory>{memory}),
            base(AllocatorRef<char, Memory>{memory}),
            title(AllocatorRef<char, Memory>{memory}),
            command_label(AllocatorRef<char, Memory>{memory}) {}

      [[nodiscard]] inline std::string_view displayName() const noexcept {
        return title.empty() ? std::string_view{branch} : std::string_view{title};
      }

      [[nodiscard]] inline std::string_view handle() const noexcept {
        std::string_view name{branch};

        for (const auto prefix : {std::string_view{"worktree-"}, std::string_view{"worktree/"}}) {
          if (name.starts_with(prefix) && name.size() > prefix.size()) {
            name.remove_prefix(prefix.size());

            return name;
          }
        }

        return name;
      }

      std::uint64_t id = 0;
      std::uint64_t source = 0;
      std::optional<std::uint64_t> workspace;
      std::optional<std::uint64_t> created_by;
      std::optional<CoordinatorReference> coordinator;
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

    template <Allocator Memory>
    struct Agent {
      inline explicit Agent(Memory& memory)
          : title(AllocatorRef<char, Memory>{memory}),
            provider_name(AllocatorRef<char, Memory>{memory}),
            workspace_label(AllocatorRef<char, Memory>{memory}),
            display_name(AllocatorRef<char, Memory>{memory}),
            icon(AllocatorRef<char, Memory>{memory}),
            detail(AllocatorRef<char, Memory>{memory}),
            plan_step(AllocatorRef<char, Memory>{memory}),
            final_message(AllocatorRef<char, Memory>{memory}) {}

      [[nodiscard]] inline std::string_view finalLine() const noexcept {
        std::string_view remaining{final_message};

        while (!remaining.empty()) {
          const auto end = remaining.find('\n');
          auto line = remaining;

          line.remove_suffix(line.size() - std::min(end, line.size()));
          const auto first = line.find_first_not_of(" \t");
          if (first != std::string_view::npos) {
            line.remove_suffix(line.size() - line.find_last_not_of(" \t") - 1);
            line.remove_prefix(first);

            return line;
          }

          if (end == std::string_view::npos) {
            break;
          }

          remaining.remove_prefix(end + 1);
        }

        return {};
      }

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

  }
}
