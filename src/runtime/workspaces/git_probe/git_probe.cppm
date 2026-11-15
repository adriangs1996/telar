export module telar.runtime.workspaces.git_probe;

import std;

import telar.runtime.platform.git_status;
import telar.platform.primitives;
import telar.base.memory.allocators;
import telar.base.memory.containers;

// Interface: workspaces/git_probe.cppm
export {
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
