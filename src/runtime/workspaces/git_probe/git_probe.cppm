export module telar.runtime.workspaces.git_probe;

import std;

import telar.runtime.workspaces.git_status;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.ds;

// The bounds of a probed workspace's path and of its branch, as the wire carries them.
namespace telar::runtime {
  inline constexpr std::size_t workspace_path_bytes = 4096;
  inline constexpr std::size_t workspace_branch_bytes = 200;
}

// Interface: workspaces/git_probe.cppm
export {
  namespace telar::runtime {

    struct WorkspaceGitRequest {
      std::uint64_t identity = 0;
      FixedText<workspace_path_bytes> path;
    };

    struct WorkspaceGitResult {
      std::uint64_t identity = 0;
      FixedText<workspace_branch_bytes> branch;
      ds::Option<bool> dirty;
      bool present = false;
      bool timed_out = false;
    };

    template <typename Probe>
    concept WorkspaceGitObserver = requires(Probe& probe, const WorkspaceGitRequest& request) {
      { probe.observe(request) } noexcept -> std::same_as<WorkspaceGitResult>;
      { probe.stop() } noexcept -> std::same_as<void>;
    };

    class WorkspaceGitProbe {
    public:
      using Request = WorkspaceGitRequest;
      using Result = WorkspaceGitResult;
      using Clock = std::chrono::steady_clock;

      explicit WorkspaceGitProbe(ConcurrentMemory& memory) noexcept;

      Result observe(const Request& request) noexcept;
      void stop() noexcept;

    private:
      GitStatusReader reader_;
    };

  }
}
