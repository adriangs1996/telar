module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.workspaces.git_probe;

import std;

namespace telar::runtime {

  template <ConcurrentAllocator Memory>
  WorkspaceGitProbe<Memory>::WorkspaceGitProbe(Memory& memory) noexcept
      : reader_(memory) {}

  template <ConcurrentAllocator Memory>
  WorkspaceGitResult WorkspaceGitProbe<Memory>::observe(const Request& request) noexcept {
    TELAR_TRACE("workspaces.gitProbe");
    const auto observed = reader_.read(request.path.view());
    Result result{.identity = request.identity};

    result.branch.assign(observed.branch.view().substr(0, 200));
    result.dirty = observed.dirty;
    result.present = observed.present;
    result.timed_out = observed.timed_out;
    return result;
  }

  template <ConcurrentAllocator Memory>
  void WorkspaceGitProbe<Memory>::stop() noexcept {
    reader_.stop();
  }

  template class WorkspaceGitProbe<ConcurrentMemory>;

}
