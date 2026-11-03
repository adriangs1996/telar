#pragma once

#include "../platform/git_status.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_platform/trace.hpp"

namespace telar::runtime {

struct WorkspaceGitRequest {
  std::uint64_t identity = 0;
  FixedText<4096> path{};
};

struct WorkspaceGitResult {
  std::uint64_t identity = 0;
  FixedText<200> branch{};
  std::optional<bool> dirty{};
  bool present = false;
  bool timed_out = false;
};

template <typename Probe>
concept WorkspaceGitObserver = requires(Probe &probe, const WorkspaceGitRequest &request) {
  { probe.observe(request) } noexcept -> std::same_as<WorkspaceGitResult>;
  { probe.stop() } noexcept -> std::same_as<void>;
};

template <ConcurrentAllocator Memory>
class WorkspaceGitProbe {
public:
  using Request = WorkspaceGitRequest;
  using Result = WorkspaceGitResult;
  using Clock = std::chrono::steady_clock;

  explicit WorkspaceGitProbe(Memory &memory) noexcept
      : reader_(memory) {}

  Result observe(const Request &request) noexcept {
    TELAR_TRACE("workspaces.gitProbe");
    const auto observed = reader_.read(request.path.view());
    Result result{.identity = request.identity};
    result.branch.assign(observed.branch.view().substr(0, 200));
    result.dirty = observed.dirty;
    result.present = observed.present;
    result.timed_out = observed.timed_out;
    return result;
  }

  void stop() noexcept {
    reader_.stop();
  }

private:
  GitStatusReader<Memory> reader_;
};

}
