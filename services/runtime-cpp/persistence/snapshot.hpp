#pragma once

#include "../agents/agent.hpp"
#include "../model/client_layouts.hpp"
#include "writer.hpp"

namespace telar::runtime::checkpoint {

template <typename Source>
concept AgentSource = requires(const Source &source, std::uint64_t identity) {
  { source.find(identity, identity) } noexcept -> std::same_as<const Agent *>;
  { source.revision() } noexcept -> std::same_as<std::uint64_t>;
};

template <Allocator Memory, AgentSource Agents>
class Snapshot {
public:
  explicit Snapshot(RuntimeModel<Memory> &model, const ClientLayouts<Memory> &layouts, const Agents &agents)
      : model_(model),
        layouts_(layouts),
        agents_(agents) {}

  std::span<const Byte> encode(std::span<Byte> buffer) {
    Writer writer{buffer, Counters{model_.workspaces.nextCounter(), model_.next_tab_id, model_.panes.nextCounter(), model_.next_pane_generation}};
    for (const auto *workspace : model_.workspaces.items()) {
      if (workspace == nullptr || workspace->tabs.empty()) {
        continue;
      }

      const auto &first = workspace->tabs.front();
      writer.append(WorkspaceRecord{workspace->id, workspace->path, workspace->name, first.id, first.label});
      for (std::size_t index = 1; index < workspace->tabs.size(); ++index) {
        const auto &tab = workspace->tabs[index];
        writer.append(TabRecord{workspace->id, tab.id, tab.label});
      }
    }

    for (const auto *worktree : model_.worktrees.items()) {
      if (worktree == nullptr) {
        continue;
      }

      const auto entry = worktree->entry();
      writer.append(WorktreeRecord{entry.worktree, entry.workspace.value_or(0), RegisterWorktree{.source = entry.source, .created_by = entry.created_by, .origin = entry.origin, .path = entry.path, .branch = entry.branch, .base = entry.base, .title = entry.title, .brief = entry.brief, .dispatched_from = entry.dispatched_from, .coordinator = entry.coordinator}});
    }

    for (const auto *pane : model_.panes.items()) {
      if (pane == nullptr || pane->output_closed || pane->exit_status || pane->close_requested || pane->launch.count() == 0) {
        continue;
      }

      PaneRecord record{pane->id, pane->location.workspace.id, pane->location.tab_id, pane->cwd, pane->terminal.screen.cols, pane->terminal.screen.rows, pane->launch.count(), pane->launch.bytes()};
      if (const auto *agent = agents_.find(pane->id, pane->generation); agent != nullptr && validResumeSession(agent->provider, agent->session.view())) {
        record.provider = agent->provider;
        record.session = agent->session.view();
        if (!agent->title.view().empty() && agent->title_source != AgentTitleSource::telar) {
          record.title = agent->title.view();
          record.title_source = agent->title_source;
        }
        record.in_pane = agent->in_pane;
      } else if (pane->restored_agent) {
        const auto &resume = *pane->restored_agent;
        record.provider = resume.provider;
        record.session = resume.session.view();
        record.title = resume.title.view();
        record.title_source = resume.title_source;
        record.in_pane = resume.in_pane;
      }
      writer.append(record);
    }

    std::array<Byte, 16 * 1024> payload;
    layouts_.exportRecords([&](std::uint64_t identity, std::uint64_t last_used, const UpdateClientLayout &layout) {
      writer.append(LayoutRecord{identity, last_used, Codec::encode(layout, payload)});
    });
    dropped = writer.dropped;
    return writer.finish();
  }

  bool changed() noexcept {
    const std::array revisions{model_.workspace_revision, layouts_.revision(), agents_.revision()};
    bool changed = revisions != revisions_;
    revisions_ = revisions;
    const auto panes = model_.panes.items();
    for (std::size_t index = 0; index < panes.size(); ++index) {
      const auto *pane = panes[index];
      const PaneStamp stamp = pane == nullptr ? PaneStamp{} : PaneStamp{pane->id, pane->cwd_revision, pane->terminal.screen.cols, pane->terminal.screen.rows, pane->output_closed || pane->exit_status.has_value() || pane->close_requested};
      changed |= stamp != stamps_[index];
      stamps_[index] = stamp;
    }

    return changed;
  }

  std::size_t dropped = 0;

private:
  struct PaneStamp {
    std::uint64_t identity = 0;
    std::uint64_t cwd_revision = 0;
    std::uint16_t columns = 0;
    std::uint16_t rows = 0;
    bool closed = false;

    bool operator==(const PaneStamp &) const = default;
  };

  RuntimeModel<Memory> &model_;
  const ClientLayouts<Memory> &layouts_;
  const Agents &agents_;
  std::array<std::uint64_t, 3> revisions_{};
  std::array<PaneStamp, 256> stamps_{};
};

}
