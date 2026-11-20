module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.workspaces.git_probe;

import std;
import telar.platform.primitives;

namespace telar::runtime {

  WorkspaceGitProbe::WorkspaceGitProbe(ConcurrentMemory& memory) noexcept
      : reader_(memory) {}

  WorkspaceGitResult WorkspaceGitProbe::observe(const Request& request) noexcept { // NOLINT(bugprone-exception-escape): assign throws only past the capacity the branch is cut to
    TELAR_TRACE("workspaces.gitProbe");
    const auto observed = reader_.read(request.path.view());
    Result result{.identity = request.identity};
    auto branch = observed.branch.view();

    branch.remove_suffix(branch.size() - std::min(branch.size(), workspace_branch_bytes));
    result.branch.assign(branch);
    result.dirty = observed.dirty;
    result.present = observed.present;
    result.timed_out = observed.timed_out;
    return result;
  }

  void WorkspaceGitProbe::stop() noexcept {
    reader_.stop();
  }

}
