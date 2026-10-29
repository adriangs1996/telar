#pragma once

#include "core/terminal_size.hpp"
#include "graphics/store.hpp"
#include "pane_layout.hpp"
#include "presentation/status_age.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "terminal/screen.hpp"
#include <algorithm>
#include <array>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>

namespace telar::gui {

enum class PaneInputSource : std::uint8_t {
  keyboard,
  key_release,
  mouse,
  terminal_report,
};

enum class ScrollDirection : std::uint8_t {
  up,
  down,
};

enum class TabCreationOutcome : std::uint8_t {
  unavailable,
  requested,
  busy,
};

struct WorkspaceDraft {
  std::string_view name;
  std::string_view path;
};

struct PaneScrollDelta {
  std::uint64_t pane_id = 0;
  std::int64_t rows = 0;
};

template <Allocator Memory>
struct Pane {
  explicit Pane(Memory &memory, std::uint64_t identity, GraphicsBudget &budget)
      : id(identity),
        screen(memory),
        graphics(memory, budget),
        title(AllocatorRef<char, Memory>{memory}),
        cwd(AllocatorRef<char, Memory>{memory}),
        foreground(AllocatorRef<char, Memory>{memory}) {}

  std::uint64_t id;
  std::uint64_t generation = 0;
  std::uint64_t attachment_generation = 0;
  TabLocation location;
  Screen<Memory> screen;
  GraphicsStore<Memory> graphics;
  String<Memory> title;
  String<Memory> cwd;
  String<Memory> foreground;
  TerminalSize size = default_terminal_size;
  bool attached = false;
  bool attaching = false;
  bool exited = false;
  bool snapshot_requested = false;
  std::uint64_t acknowledged_frame = 0;
  PaneProgressState progress_state = PaneProgressState::remove;
  std::optional<Byte> progress_percent;
};

template <Allocator Memory>
struct Tab {
  explicit Tab(Memory &memory, TabLocation identity)
      : location(identity),
        label(AllocatorRef<char, Memory>{memory}),
        foreground(AllocatorRef<char, Memory>{memory}) {}

  [[nodiscard]] std::string_view applicationName(const Pane<Memory> *pane) const noexcept {
    constexpr std::string_view fallback = "shell";
    if (pane != nullptr) {
      if (!pane->foreground.empty()) {
        return pane->foreground;
      }

      if (pane->id != foreground_pane) {
        return fallback;
      }
    }

    return foreground.empty() ? fallback : std::string_view{foreground};
  }

  bool observeForeground(PaneForeground report) {
    if (foreground_pane == report.pane_id && foreground == report.name) {
      return false;
    }

    foreground = report.name;
    foreground_pane = report.pane_id;

    return true;
  }

  bool observeForegrounds(std::span<const PaneForeground> names) {
    if (names.empty()) {
      return false;
    }

    auto selected = names.front();
    for (const auto name : names) {
      if (name.pane_id == focused_pane) {
        selected = name;
      }
    }

    return observeForeground(selected);
  }

  TabLocation location;
  String<Memory> label;
  String<Memory> foreground;
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
  explicit Workspace(Memory &memory, WorkspaceLocation identity = {})
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

  explicit Worktree(Memory &memory)
      : path(AllocatorRef<char, Memory>{memory}),
        branch(AllocatorRef<char, Memory>{memory}),
        base(AllocatorRef<char, Memory>{memory}),
        title(AllocatorRef<char, Memory>{memory}),
        command_label(AllocatorRef<char, Memory>{memory}) {}

  [[nodiscard]] std::string_view displayName() const noexcept {
    return title.empty() ? std::string_view{branch} : std::string_view{title};
  }

  [[nodiscard]] std::string_view handle() const noexcept {
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
  explicit Agent(Memory &memory)
      : title(AllocatorRef<char, Memory>{memory}),
        provider_name(AllocatorRef<char, Memory>{memory}),
        workspace_label(AllocatorRef<char, Memory>{memory}),
        display_name(AllocatorRef<char, Memory>{memory}),
        icon(AllocatorRef<char, Memory>{memory}),
        detail(AllocatorRef<char, Memory>{memory}),
        plan_step(AllocatorRef<char, Memory>{memory}),
        final_message(AllocatorRef<char, Memory>{memory}) {}

  [[nodiscard]] std::string_view finalLine() const noexcept {
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
