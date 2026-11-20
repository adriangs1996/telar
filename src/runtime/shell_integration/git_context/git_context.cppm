module;
#include "tbc/annotations.hpp"

export module telar.runtime.shell_integration.git_context;

import std;
import telar.sys.posix;

import telar.git;
import telar.wire.pane_io;
import telar.runtime.platform.request_worker;
import telar.base.memory.allocators;
import telar.base.memory.containers;

// The git context of integrated shells: after each command, the repository their working
// directory is in, read natively on a worker so a large work tree never stalls the runtime.
export namespace telar::runtime {

  struct ShellGitRequest {
    std::uint64_t pane = 0;
    std::uint64_t generation = 0;
    FixedText<PATH_MAX> directory;
  };

  struct ShellGitSummary {
    static constexpr std::size_t branch_bytes = 256;

    bool repository = false;
    bool detached = false;
    FixedText<branch_bytes> branch;
    bool divergence_known = false;
    std::uint32_t ahead = 0;
    std::uint32_t behind = 0;
    bool changes_known = false;
    std::uint32_t staged = 0;
    std::uint32_t unstaged = 0;
    std::uint32_t conflicted = 0;

    bool operator==(const ShellGitSummary&) const noexcept = default;

    [[nodiscard]] PaneGit message(std::uint64_t pane) const noexcept;
  };

  struct ShellGitResult {
    std::uint64_t pane = 0;
    std::uint64_t generation = 0;
    ShellGitSummary summary;
  };

  // Runs on the worker. The reader keeps its caches between reads, so a prompt in the same
  // repository rechecks the work tree without parsing the index or the history again.
  class ShellGitReader {
  public:
    using Request = ShellGitRequest;
    using Result = ShellGitResult;

    ShellGitReader();

    Result observe(const Request& request) noexcept;

    void stop() noexcept;

  private:
    SystemAllocator memory_;
    MemoryAdapter<SystemAllocator> erased_{memory_};
    git::StatusReader reader_;
  };

  // One read at a time: while one runs, the latest request of each other pane waits.
  class ShellGitService {
  public:
    explicit ShellGitService(ConcurrentMemory& memory);

    void request(std::uint64_t pane, std::uint64_t generation, std::string_view directory);

    // The consumer is the caller's type; the queue's collect is a template over it too.
    template <typename Consumer>
    TBC_GENERIC inline void collect(Consumer&& consume) {
      queue_.collect(worker_, std::forward<Consumer>(consume));
    }

    int descriptor() const noexcept;

  private:
    ObservationWorker<ShellGitReader> worker_;
    SerialQueue<ShellGitRequest> queue_;
  };

}
