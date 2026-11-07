module;
#include "telar_platform/trace_macro.hpp"
#include <limits>
#include <utility>
#include <concepts>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>
#include <type_traits>
#include <cstdio>
#include <variant>
#include <bit>
#include <stdexcept>

#include <array>
#include <optional>
#include <string_view>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <span>
#include <exception>
#include <cstddef>
#include <cerrno>
#include <sys/types.h>
#include <limits.h>
#include <atomic>
#include <chrono>
#include <poll.h>
#include <sys/wait.h>
#include <charconv>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>

export module telar.runtime.workspaces.git_probe;

export import telar.runtime.platform.git_status;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

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

  inline explicit WorkspaceGitProbe(Memory &memory) noexcept
      : reader_(memory) {}

  inline Result observe(const Request &request) noexcept {
    TELAR_TRACE("workspaces.gitProbe");
    const auto observed = reader_.read(request.path.view());
    Result result{.identity = request.identity};
    result.branch.assign(observed.branch.view().substr(0, 200));
    result.dirty = observed.dirty;
    result.present = observed.present;
    result.timed_out = observed.timed_out;
    return result;
  }

  inline void stop() noexcept {
    reader_.stop();
  }

private:
  GitStatusReader<Memory> reader_;
};

}
}
