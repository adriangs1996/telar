#pragma once

#include "../platform/observation_worker.hpp"
#include "../workspaces/git_probe.hpp"
#include "limit_service.hpp"

namespace telar::runtime {

template <Allocator Memory, WorkspaceGitObserver Probe>
class WorkspaceGitService {
public:
  using Clock = std::chrono::steady_clock;
  static constexpr auto probe_interval = std::chrono::seconds{5};

  explicit WorkspaceGitService(RuntimeModel<Memory> &model, LimitService<Memory> &limits, Probe &probe)
      : model_(model),
        limits_(limits),
        worker_(probe) {}

  std::chrono::nanoseconds tick(Clock::time_point now) {
    collect(now);
    if (pending_) {
      return probe_interval;
    }
    if (now < next_check_ && checked_revision_ == model_.workspace_revision) {
      return next_check_ - now;
    }

    Workspace<Memory> *oldest = nullptr;
    next_check_ = now + probe_interval;
    checked_revision_ = model_.workspace_revision;
    for (auto *workspace : model_.workspaces.items()) {
      if (workspace == nullptr) {
        continue;
      }

      const auto due = workspace->git_checked_at + probe_interval;
      next_check_ = std::min(next_check_, due);
      if (due <= now && (oldest == nullptr || workspace->git_checked_at < oldest->git_checked_at)) {
        oldest = workspace;
      }
    }

    if (oldest != nullptr) {
      WorkspaceGitRequest request{.identity = oldest->id};
      request.path.assign(oldest->path);
      if (worker_.submit(request)) {
        pending_ = oldest->id;
      }
      return probe_interval;
    }

    return next_check_ - now;
  }

  void collect(Clock::time_point now) {
    worker_.collect([&](const WorkspaceGitResult &result) {
      if (pending_ != result.identity) {
        return;
      }

      pending_.reset();
      next_check_ = now;
      auto *workspace = model_.workspaces.find(result.identity);
      if (workspace == nullptr) {
        return;
      }

      if (result.timed_out && !workspace->git_timed_out) {
        limits_.report(LimitReach{.name = "gitstatus.status_timeout", .noun = "milliseconds", .value = std::chrono::duration_cast<std::chrono::milliseconds>(git_status_timeout).count()});
      }
      workspace->git_timed_out = result.timed_out;
      workspace->git_checked_at = now;
      const auto branch = result.present ? result.branch.view() : std::string_view{};
      const bool dirty = result.present && result.dirty.value_or(workspace->git_dirty);
      if (workspace->git_branch.view() != branch || workspace->git_dirty != dirty) {
        workspace->git_branch.assign(branch);
        workspace->git_dirty = dirty;
        ++model_.workspace_revision;
      }
    });
  }

  int descriptor() const noexcept {
    return worker_.descriptor();
  }

private:
  RuntimeModel<Memory> &model_;
  LimitService<Memory> &limits_;
  ObservationWorker<Probe> worker_;
  std::optional<std::uint64_t> pending_;
  Clock::time_point next_check_{};
  std::uint64_t checked_revision_ = 0;
};

}
