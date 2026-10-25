#pragma once

#include "../model/runtime_model.hpp"
#include "../platform/observation_worker.hpp"
#include "../worktrees/detection_probe.hpp"

namespace telar::runtime {

template <Allocator Memory, WorktreeDetector Probe>
class WorktreeDetectionService {
public:
  explicit WorktreeDetectionService(RuntimeModel<Memory> &model, Probe &probe)
      : model_(model),
        worker_(probe) {}

  void tick() {
    collect();
    if (pending_) {
      return;
    }

    for (auto *pane : model_.panes.items()) {
      if (pane == nullptr || pane->worktree_checked_cwd == pane->cwd_revision) {
        continue;
      }
      pane->worktree_checked_cwd = pane->cwd_revision;
      if (pane->exit_status || pane->location.workspace.kind != WorkspaceLocation::Kind::workspace || !pane->cwd.starts_with('/') || model_.worktrees.containing(pane->cwd) != nullptr) {
        continue;
      }

      WorktreeDetectionRequest request{.pane = pane->id, .generation = pane->generation, .cwd_revision = pane->cwd_revision};
      request.cwd.assign(pane->cwd);
      if (worker_.submit(request)) {
        pending_ = true;
      } else {
        pane->worktree_checked_cwd.reset();
      }
      return;
    }
  }

  void collect() {
    worker_.collect([&](const WorktreeDetectionResult &result) {
      pending_ = false;
      auto *pane = model_.panes.find(result.pane);
      if (pane == nullptr || pane->generation != result.generation || pane->cwd_revision != result.cwd_revision || result.root_length == 0 || result.root_length > pane->cwd.size() || pane->location.workspace.kind != WorkspaceLocation::Kind::workspace) {
        return;
      }

      try {
        const auto registered = model_.worktrees.registerEntry(RegisterWorktree{
            .source = model_.worktrees.sourceFor(pane->location.workspace.id),
            .origin = WorktreeOrigin::external,
            .path = std::string_view{pane->cwd}.substr(0, result.root_length),
            .branch = result.branch.view(),
        });
        model_.workspace_revision += registered.created;
      } catch (const RequestError &) {
      }
    });
  }

  int descriptor() const noexcept {
    return worker_.descriptor();
  }

private:
  RuntimeModel<Memory> &model_;
  ObservationWorker<Probe> worker_;
  bool pending_ = false;
};

}
