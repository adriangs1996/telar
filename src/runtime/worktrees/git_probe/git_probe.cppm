export module telar.runtime.worktrees.git_probe;

import std;
import telar.tbc;

export import telar.runtime.platform.git_status;
import telar.platform.primitives;

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

    template <Allocator Memory>
    class GitBaseDistance {
    public:
      using Clock = std::chrono::steady_clock;

      explicit GitBaseDistance(Memory& memory, const std::atomic<bool>& cancelled) noexcept;

      GitDistance read(std::string_view root, std::string_view base, Clock::time_point deadline);

    private:
      template <std::size_t Capacity>
      FixedText<Capacity> line(std::string_view root, Clock::time_point deadline, std::initializer_list<std::string_view> arguments);

      static void parseDiff(std::string_view output, GitDistance& result) noexcept;
      [[noreturn]] static void reject();

      Memory& memory_;
      const std::atomic<bool>& cancelled_;
    };

    extern template class GitBaseDistance<ConcurrentMemory>;

  }
}

// Interface: worktrees/detection_probe.cppm
export {
  namespace telar::runtime {

    struct WorktreeDetectionRequest {
      std::uint64_t pane = 0;
      std::uint64_t generation = 0;
      std::uint64_t cwd_revision = 0;
      FixedText<4096> cwd{};
    };

    struct WorktreeDetectionResult {
      std::uint64_t pane = 0;
      std::uint64_t generation = 0;
      std::uint64_t cwd_revision = 0;
      std::size_t root_length = 0;
      FixedText<200> branch{};
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

      Result observe(const Request& request) noexcept;
      void stop() noexcept;
    };

  }
}

// Interface: worktrees/git_probe.cppm
export {
  namespace telar::runtime {

    struct WorktreeProbeRequest {
      std::uint64_t identity = 0;
      FixedText<4096> path;
      FixedText<200> base{};
    };

    enum class GitProbeTimeout {
      none,
      status,
      distance,
    };

    struct WorktreeProbeResult {
      std::uint64_t identity = 0;
      bool present = false;
      bool measured = false;
      bool dirty = false;
      FixedText<200> branch{};
      FixedText<200> base{};
      std::uint32_t added = 0;
      std::uint32_t removed = 0;
      std::uint32_t files = 0;
      std::uint32_t ahead = 0;
      GitProbeTimeout timeout = GitProbeTimeout::none;
    };

    template <ConcurrentAllocator Memory>
    class WorktreeGitProbe {
    public:
      using Request = WorktreeProbeRequest;
      using Result = WorktreeProbeResult;

      explicit WorktreeGitProbe(Memory& memory);

      void stop() noexcept;
      Result observe(const Request& request) noexcept;

    private:
      static void assignBranch(FixedText<200>& destination, std::string_view value);
      static void discoverBase(std::string_view root, FixedText<200>& base);

      Memory& memory_;
      std::atomic<bool> cancelled_{false};
      GitStatusReader<Memory> status_;
      // Watches cancelled_.
      tbc::view<GitBaseDistance<Memory>, tbc::lt::self> distance_;
    };

    extern template class WorktreeGitProbe<ConcurrentMemory>;

  }
}
