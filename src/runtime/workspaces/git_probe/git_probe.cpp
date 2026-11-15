module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.workspaces.git_probe;

import std;
import telar.platform.primitives;

namespace telar::runtime {

  WorkspaceGitProbe::WorkspaceGitProbe(ConcurrentMemory& memory) noexcept
      : reader_(memory) {}

  WorkspaceGitResult WorkspaceGitProbe::observe(const Request& request) noexcept {
    TELAR_TRACE("workspaces.gitProbe");
    const auto observed = reader_.read(request.path.view());
    Result result{.identity = request.identity};

    result.branch.assign(observed.branch.view().substr(0, 200));
    result.dirty = observed.dirty;
    result.present = observed.present;
    result.timed_out = observed.timed_out;
    return result;
  }

  void WorkspaceGitProbe::stop() noexcept {
    reader_.stop();
  }

}
