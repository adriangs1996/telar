export module telar.runtime.workspaces.worktrees.git_probe;

import std;
import telar.tbc;

import telar.runtime.workspaces.git_status;
import telar.base.memory.allocators;
import telar.base.memory.containers;

// The bounds of a probed checkout's path and of a branch name, as the wire carries them.
namespace telar::runtime {
  inline constexpr std::size_t probed_path_bytes = 4096;
  inline constexpr std::size_t probed_branch_bytes = 200;
}

// Interface: worktrees/base_distance.cppm
export {
  namespace telar::runtime {

    inline constexpr auto git_distance_timeout = std::chrono::seconds{10};

    struct GitDistance {
      std::uint32_t added = 0;
      std::uint32_t removed = 0;
      std::uint32_t files = 0;
      std::uint32_t ahead = 0;
    };

    class GitBaseDistance {
    public:
      using Clock = std::chrono::steady_clock;

      explicit GitBaseDistance(ConcurrentMemory& memory, const std::atomic<bool>& cancelled) noexcept;

      GitDistance read(std::string_view root, std::string_view base, Clock::time_point deadline);

    private:
      template <std::size_t Capacity>
      FixedText<Capacity> line(std::string_view root, Clock::time_point deadline, std::initializer_list<std::string_view> arguments);

      static void parseDiff(std::string_view output, GitDistance& result) noexcept;
      [[noreturn]] static void reject();

      ConcurrentMemory& memory_;
      const std::atomic<bool>& cancelled_;
    };

  }
}

// Interface: worktrees/detection_probe.cppm
export {
  namespace telar::runtime {

    struct WorktreeDetectionRequest {
      std::uint64_t pane = 0;
      std::uint64_t generation = 0;
      std::uint64_t cwd_revision = 0;
      FixedText<probed_path_bytes> cwd;
    };

    struct WorktreeDetectionResult {
      std::uint64_t pane = 0;
      std::uint64_t generation = 0;
      std::uint64_t cwd_revision = 0;
      std::size_t root_length = 0;
      FixedText<probed_branch_bytes> branch;
    };

    template <typename Probe>
    concept WorktreeDetector = requires(Probe& probe, const WorktreeDetectionRequest& request) {
      { probe.observe(request) } noexcept -> std::same_as<WorktreeDetectionResult>;
      { probe.stop() } noexcept -> std::same_as<void>;
    };

    class WorktreeDetectionProbe {
    public:
      using Request = WorktreeDetectionRequest;
      using Result = WorktreeDetectionResult;

      static Result observe(const Request& request) noexcept;
      void stop() noexcept;
    };

  }
}

// Interface: worktrees/git_probe.cppm
export {
  namespace telar::runtime {

    struct WorktreeProbeRequest {
      std::uint64_t identity = 0;
      FixedText<probed_path_bytes> path;
      FixedText<probed_branch_bytes> base;
    };

    enum class GitProbeTimeout : std::uint8_t {
      none,
      status,
      distance,
    };

    struct WorktreeProbeResult {
      std::uint64_t identity = 0;
      bool present = false;
      bool measured = false;
      bool dirty = false;
      FixedText<probed_branch_bytes> branch;
      FixedText<probed_branch_bytes> base;
      std::uint32_t added = 0;
      std::uint32_t removed = 0;
      std::uint32_t files = 0;
      std::uint32_t ahead = 0;
      GitProbeTimeout timeout = GitProbeTimeout::none;
    };

    class WorktreeGitProbe {
    public:
      using Request = WorktreeProbeRequest;
      using Result = WorktreeProbeResult;

      explicit WorktreeGitProbe(ConcurrentMemory& memory);

      void stop() noexcept;
      Result observe(const Request& request) noexcept;

    private:
      static void assignBranch(FixedText<probed_branch_bytes>& destination, std::string_view value);
      static void discoverBase(std::string_view root, FixedText<probed_branch_bytes>& base);

      ConcurrentMemory& memory_;
      std::atomic<bool> cancelled_{false};
      GitStatusReader status_;
      // Watches cancelled_.
      tbc::val_self<GitBaseDistance> distance_;
    };

  }
}
