#pragma once

#include "../platform/launch_program.hpp"
#include "../worktrees/git_probe.hpp"
#include "limit_service.hpp"
#include "telar_config/agents/provider.hpp"
#include "workspace_service.hpp"

namespace telar::runtime {

template <Allocator Memory, EventLoop Poller, HistoryEventSink History = DiscardedHistory>
class WorktreeService {
public:
  explicit WorktreeService(Memory &memory, RuntimeModel<Memory> &model, WorkspaceService<Memory, Poller, History> &workspaces, LimitService<Memory> &limits)
      : memory_(memory),
        model_(model),
        workspaces_(workspaces),
        limits_(limits) {}

  void registerEntry(ClientSession<Memory> &client, const RegisterWorktree &request) {
    workspaces_.require(WorkspaceLocation{.id = request.source});
    if (request.created_by) {
      const auto *pane = model_.panes.find(*request.created_by);
      if (client.verified_pane != *request.created_by || pane == nullptr || client.verified_generation != pane->generation) {
        throw RequestError{FailureCode::foreign_process, "Only a process inside the pane may register for it"};
      }
    }

    const auto result = model_.worktrees.registerEntry(request);
    ++model_.workspace_revision;
    client.connection.send(result);
  }

  void launch(ClientSession<Memory> &client, const LaunchWorktree &request) {
    auto &entry = require(request.worktree);
    auto *workspace = entry.workspace ? model_.workspaces.find(*entry.workspace) : nullptr;
    const bool created = workspace == nullptr;
    if (created) {
      const auto identity = model_.workspaces.nextId();
      const auto title = entry.title.view().empty() ? entry.branch.view() : entry.title.view();
      auto owned = makeOwned<Workspace<Memory>>(memory_, memory_, identity, entry.path, utf8Prefix(title, 128));
      workspace = owned.get();
      model_.workspaces.insertProvisional(identity, std::move(owned));
    }

    Pane<Memory> *pane = nullptr;
    try {
      auto launch = request.launch;
      launch.cwd = entry.path;
      launch.cwd_source = 0;
      pane = &workspaces_.launchBackground(LaunchTab{request.request_id, workspace->id, request.label, request.size, launch});
    } catch (...) {
      if (created) {
        model_.workspaces.erase(workspace->id);
      }

      throw;
    }

    model_.workspaces.advanceCounter(workspace->id + 1);
    entry.workspace = workspace->id;
    entry.command_pane = pane->id;
    entry.command_state = CommandState::running;
    entry.command_exit = 0;
    const auto program = launchedProgram(request.launch.arguments);
    entry.command_label.assign(utf8Prefix(program.substr(program.rfind('/') + 1), 48));
    ++model_.workspace_revision;
    client.connection.send(PaneOpened{request.request_id, pane->id, pane->location, created, pane->generation});
  }

  void forget(ClientSession<Memory> &client, const ForgetWorktree &request) {
    auto &entry = require(request.worktree);
    if (entry.workspace) {
      workspaces_.closeWorkspace(*entry.workspace);
    }

    model_.worktrees.remove(request.worktree);
    ++model_.workspace_revision;
    client.connection.send(RequestCompleted{.request_id = request.request_id});
  }

  template <typename Background>
  void observe(Background &background) {
    if (observing_) {
      return;
    }
    const auto now = std::chrono::steady_clock::now();
    Worktree<Memory> *selected = nullptr;
    for (auto *entry : model_.worktrees.items()) {
      if (entry == nullptr || entry->state == WorktreeState::gone) {
        continue;
      }
      const auto interval = entry->command_state == CommandState::running && entry->probe_failures < 2 ? std::chrono::seconds{5} : std::chrono::seconds{30};
      if (now - entry->checked_at < interval) {
        continue;
      }
      if (selected == nullptr || selected->checked_at > entry->checked_at) {
        selected = entry;
      }
    }
    if (selected == nullptr) {
      return;
    }
    WorktreeProbeRequest request{};
    request.identity = selected->id;
    request.path.assign(selected->path);
    request.base = selected->base;
    if (background.observeWorktree(request)) {
      observing_ = selected->id;
    }
  }

  void observed(const WorktreeProbeResult &result) {
    if (observing_ != result.identity) {
      return;
    }
    observing_.reset();
    auto *entry = model_.worktrees.find(result.identity);
    if (result.timeout != GitProbeTimeout::none && (entry == nullptr || entry->probe_failures == 0)) {
      const auto timeout = result.timeout == GitProbeTimeout::status ? git_status_timeout : git_distance_timeout;
      const auto name = result.timeout == GitProbeTimeout::status ? "gitstatus.status_timeout" : "gitstatus.base_distance_timeout";
      limits_.report(LimitReach{.name = name, .noun = "milliseconds", .value = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(timeout).count())});
    }
    if (entry == nullptr) {
      return;
    }
    entry->checked_at = std::chrono::steady_clock::now();
    bool changed = false;
    if (!result.present) {
      changed = entry->state != WorktreeState::gone;
      entry->state = WorktreeState::gone;
    } else {
      if (!result.branch.view().empty() && result.branch.view() != entry->branch.view()) {
        entry->branch = result.branch;
        changed = true;
      }
      if (entry->base.view().empty() && !result.base.view().empty()) {
        entry->base = result.base;
        changed = true;
      }
      if (result.measured) {
        entry->probe_failures = 0;
        const bool pending = result.dirty || result.files != 0 || result.ahead != 0;
        entry->had_changes |= pending;
        const auto state = !pending && entry->had_changes ? WorktreeState::integrated : WorktreeState::active;
        changed |= entry->state != state || entry->diff_added != result.added || entry->diff_removed != result.removed || entry->diff_files != result.files || entry->commits_ahead != result.ahead;
        entry->state = state;
        entry->diff_added = result.added;
        entry->diff_removed = result.removed;
        entry->diff_files = result.files;
        entry->commits_ahead = result.ahead;
      } else {
        entry->probe_failures = std::min(entry->probe_failures + 1, 2u);
      }
    }
    model_.workspace_revision += changed;
  }

  void refresh() noexcept {
    for (auto *entry : model_.worktrees.items()) {
      if (entry == nullptr) {
        continue;
      }

      if (entry->command_pane) {
        const auto *pane = model_.panes.find(*entry->command_pane);
        if (pane != nullptr && pane->exit_status) {
          const auto status = *pane->exit_status;
          entry->command_exit = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
          entry->command_state = CommandState::exited;
          entry->command_pane.reset();
          ++model_.workspace_revision;
        }
      }

      if (entry->workspace && model_.workspaces.find(*entry->workspace) == nullptr) {
        entry->workspace.reset();
        ++model_.workspace_revision;
      }
    }
  }

private:
  Worktree<Memory> &require(std::uint64_t identity) const {
    auto *entry = model_.worktrees.find(identity);
    if (entry == nullptr) {
      throw RequestError{FailureCode::worktree_not_found, "worktree not found"};
    }

    return *entry;
  }

  std::optional<std::uint64_t> observing_;
  Memory &memory_;
  RuntimeModel<Memory> &model_;
  WorkspaceService<Memory, Poller, History> &workspaces_;
  LimitService<Memory> &limits_;
};

}
