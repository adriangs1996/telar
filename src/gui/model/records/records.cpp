module telar.gui.model.records;

import std;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.wire.agents;
import telar.wire.layout;
import telar.wire.vocabulary;

namespace telar::gui {

  std::uint64_t StatusAgeInterval::elapsed(std::uint64_t now_ns) const noexcept {
    const auto delta = now_ns > sampled_ns ? now_ns - sampled_ns : 0;

    return age_ns + std::min(std::numeric_limits<std::uint64_t>::max() - age_ns, delta);
  }

  std::uint32_t StatusAgeInterval::seconds(std::uint64_t now_ns) const noexcept {
    return static_cast<std::uint32_t>(std::min<std::uint64_t>(std::numeric_limits<std::uint32_t>::max(), elapsed(now_ns) / nanoseconds_per_second));
  }

  bool StatusAgeSample::continues(const StatusAgeSample& previous) const noexcept {
    return pane_id == previous.pane_id && pane_generation == previous.pane_generation && status == previous.status && provider == previous.provider && reported_seconds >= previous.reported_seconds;
  }

  void StatusAge::observe(StatusAgeSample sample, std::uint64_t now_ns) noexcept {
    auto age_ns = static_cast<std::uint64_t>(sample.reported_seconds) * StatusAgeInterval::nanoseconds_per_second;

    if (sample.continues(sample_)) {
      age_ns = std::max(age_ns, interval_.elapsed(now_ns));
    }

    sample_ = sample;
    interval_ = {.age_ns = age_ns, .sampled_ns = now_ns};
  }

  bool StatusAge::observed() const noexcept {
    return sample_.pane_id != 0;
  }

  StatusAgeInterval StatusAge::interval() const noexcept {
    return interval_;
  }

  template <Allocator Memory>
  Tab<Memory>::Tab(Memory& memory, TabLocation identity)
      : location(identity),
        label(AllocatorRef<char, Memory>{memory}),
        foreground(AllocatorRef<char, Memory>{memory}),
        directory(AllocatorRef<char, Memory>{memory}),
        members(AllocatorRef<TabMember, Memory>{memory}) {}

  template <Allocator Memory>
  void Tab<Memory>::observeForeground(PaneForeground report) {
    if (foreground_pane == report.pane_id) {
      foreground = report.name;
    }

    for (auto& member : members) {
      if (member.pane_id == report.pane_id) {
        member.foreground.assign(report.name);
      }
    }
  }

  template <Allocator Memory>
  void Tab<Memory>::observePanes(std::span<const TabPane> panes) {
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

  template <Allocator Memory>
  Workspace<Memory>::Workspace(Memory& memory, WorkspaceLocation identity)
      : location(identity),
        name(AllocatorRef<char, Memory>{memory}),
        path(AllocatorRef<char, Memory>{memory}),
        branch(AllocatorRef<char, Memory>{memory}) {}

  template <Allocator Memory>
  Worktree<Memory>::Worktree(Memory& memory)
      : path(AllocatorRef<char, Memory>{memory}),
        branch(AllocatorRef<char, Memory>{memory}),
        base(AllocatorRef<char, Memory>{memory}),
        title(AllocatorRef<char, Memory>{memory}),
        command_label(AllocatorRef<char, Memory>{memory}) {}

  template <Allocator Memory>
  std::string_view Worktree<Memory>::displayName() const noexcept {
    return title.empty() ? std::string_view{branch} : std::string_view{title};
  }

  template <Allocator Memory>
  std::string_view Worktree<Memory>::handle() const noexcept {
    std::string_view name{branch};

    for (const auto prefix : {std::string_view{"worktree-"}, std::string_view{"worktree/"}}) {
      if (name.starts_with(prefix) && name.size() > prefix.size()) {
        name.remove_prefix(prefix.size());

        return name;
      }
    }

    return name;
  }

  template <Allocator Memory>
  Agent<Memory>::Agent(Memory& memory)
      : title(AllocatorRef<char, Memory>{memory}),
        provider_name(AllocatorRef<char, Memory>{memory}),
        workspace_label(AllocatorRef<char, Memory>{memory}),
        display_name(AllocatorRef<char, Memory>{memory}),
        icon(AllocatorRef<char, Memory>{memory}),
        detail(AllocatorRef<char, Memory>{memory}),
        plan_step(AllocatorRef<char, Memory>{memory}),
        final_message(AllocatorRef<char, Memory>{memory}) {}

  template <Allocator Memory>
  std::string_view Agent<Memory>::finalLine() const noexcept {
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

  template struct Tab<Memory>;
  template struct Tab<ConcurrentMemory>;
  template struct Workspace<Memory>;
  template struct Workspace<ConcurrentMemory>;
  template struct Worktree<Memory>;
  template struct Worktree<ConcurrentMemory>;
  template struct Agent<Memory>;
  template struct Agent<ConcurrentMemory>;

}
