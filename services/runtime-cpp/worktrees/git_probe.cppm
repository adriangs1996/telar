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

export module telar.runtime.worktrees.git_probe;

export import telar.runtime.platform.git_status;
export import telar.platform;
import telar.base.diagnostics;
import telar.client.protocol;
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

  inline explicit GitBaseDistance(Memory &memory, const std::atomic<bool> &cancelled) noexcept
      : memory_(memory),
        cancelled_(cancelled) {}

  inline GitDistance read(std::string_view root, std::string_view base, Clock::time_point deadline) {
    if (base.empty() || base.starts_with('-')) {
      reject();
    }

    const auto ancestor = line<64>(root, deadline, {"merge-base", base, "HEAD"});
    const auto difference = line<4096>(root, deadline, {"diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all", "--shortstat", ancestor.view(), "--"});
    GitDistance result;
    parseDiff(difference.view(), result);
    String<Memory> range{ancestor.view(), AllocatorRef<char, Memory>{memory_}};
    range += "..HEAD";
    const auto count = line<32>(root, deadline, {"rev-list", "--count", range, "--"});
    const auto text = count.view();
    const auto parsed = std::from_chars(text.data(), text.data() + text.size(), result.ahead);
    if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) {
      reject();
    }

    return result;
  }

private:
  template <std::size_t Capacity>
  inline FixedText<Capacity> line(std::string_view root, Clock::time_point deadline, std::initializer_list<std::string_view> arguments) {
    GitRepository git{memory_, root, deadline, cancelled_};
    constexpr std::size_t maximum_output = 4096;
    const auto output = git.run(arguments, false, maximum_output);
    const auto trimmed = GitFiles::trim(output, " \r\n");
    if (trimmed.size() > Capacity) {
      reject();
    }

    FixedText<Capacity> result;
    result.assign(trimmed);
    return result;
  }

  inline static void parseDiff(std::string_view output, GitDistance &result) noexcept {
    while (!output.empty()) {
      const auto delimiter = output.find(',');
      const auto part = GitFiles::trim(output.substr(0, delimiter), " \n");
      output = delimiter == std::string_view::npos ? std::string_view{} : output.substr(delimiter + 1);
      const auto separator = part.find(' ');
      if (separator == std::string_view::npos) {
        continue;
      }

      std::uint32_t value = 0;
      const auto parsed = std::from_chars(part.data(), part.data() + separator, value);
      if (parsed.ec != std::errc{} || parsed.ptr != part.data() + separator) {
        continue;
      }
      const auto label = part.substr(separator + 1);
      if (label.starts_with("file")) {
        result.files = value;
      } else if (label.starts_with("insertion")) {
        result.added = value;
      } else if (label.starts_with("deletion")) {
        result.removed = value;
      }
    }
  }

  [[noreturn]] inline static void reject() {
    throw RequestError{FailureCode::invalid_request, "Git distance unavailable"};
  }

  Memory &memory_;
  const std::atomic<bool> &cancelled_;
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
concept WorktreeDetector = requires(Probe &probe, const WorktreeDetectionRequest &request) {
  { probe.observe(request) } noexcept -> std::same_as<WorktreeDetectionResult>;
  { probe.stop() } noexcept -> std::same_as<void>;
};

class WorktreeDetectionProbe {
public:
  using Request = WorktreeDetectionRequest;
  using Result = WorktreeDetectionResult;

  inline Result observe(const Request &request) noexcept {
    TELAR_TRACE("worktrees.detect");
    Result result{.pane = request.pane, .generation = request.generation, .cwd_revision = request.cwd_revision};
    LinkedWorktree reader;
    if (const auto found = reader.find(request.cwd.view())) {
      try {
        Text16<4096, false>::validate(request.cwd.view().substr(0, found->root_length));
        DisplayText16<200, false>::validate(found->branch);
        result.branch.assign(found->branch);
        result.root_length = found->root_length;
      } catch (const EncodingError &) {
      }
    }
    return result;
  }

  inline void stop() noexcept {}
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
  distance
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

  inline explicit WorktreeGitProbe(Memory &memory)
      : memory_(memory),
        status_(memory),
        distance_(memory, cancelled_) {}

  inline void stop() noexcept {
    cancelled_ = true;
    status_.stop();
  }

  inline Result observe(const Request &request) noexcept {
    TELAR_TRACE("worktrees.gitProbe");
    Result result{.identity = request.identity};
    try {
      String<Memory> path{request.path.view(), AllocatorRef<char, Memory>{memory_}};
      struct stat filesystem_status{};
      if (::stat(path.c_str(), &filesystem_status) != 0 || !S_ISDIR(filesystem_status.st_mode)) {
        return result;
      }
      result.present = true;
      const auto status = status_.read(request.path.view());
      if (status.present) {
        try {
          assignBranch(result.branch, status.branch.view());
        } catch (const EncodingError &) {
        }
      }
      result.timeout = status.timed_out ? GitProbeTimeout::status : GitProbeTimeout::none;
      result.base = request.base;
      if (result.base.view().empty()) {
        try {
          discoverBase(request.path.view(), result.base);
        } catch (const EncodingError &) {
        }
      }
      if (!status.dirty) {
        return result;
      }
      result.dirty = *status.dirty;
      const auto deadline = std::chrono::steady_clock::now() + git_distance_timeout;
      try {
        const auto measured = distance_.read(request.path.view(), result.base.view(), deadline);
        result.added = measured.added;
        result.removed = measured.removed;
        result.files = measured.files;
        result.ahead = measured.ahead;
        result.measured = true;
      } catch (const RequestError &error) {
        if (error.code() == FailureCode::resource_limit && std::chrono::steady_clock::now() >= deadline) {
          result.timeout = GitProbeTimeout::distance;
        }
      }
    } catch (...) {
    }
    return result;
  }

private:
  inline static void assignBranch(FixedText<200> &destination, std::string_view value) {
    DisplayText16<200, false>::validate(value);
    destination.assign(value);
  }

  inline static void discoverBase(std::string_view root, FixedText<200> &base) {
    LinkedWorktree reader;
    if (const auto branch = reader.mainBranch(root)) {
      assignBranch(base, *branch);
    }
  }

  Memory &memory_;
  std::atomic<bool> cancelled_{false};
  GitStatusReader<Memory> status_;
  GitBaseDistance<Memory> distance_;
};

}
}
