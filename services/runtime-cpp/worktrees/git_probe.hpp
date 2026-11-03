#pragma once

#include "../diagnostics/trace.hpp"
#include "../platform/git_status.hpp"
#include "base_distance.hpp"
#include "linked_worktree.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include <fcntl.h>
#include <sys/stat.h>

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

  explicit WorktreeGitProbe(Memory &memory)
      : memory_(memory),
        status_(memory),
        distance_(memory, cancelled_) {}

  void stop() noexcept {
    cancelled_ = true;
    status_.stop();
  }

  Result observe(const Request &request) noexcept {
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
  static void assignBranch(FixedText<200> &destination, std::string_view value) {
    DisplayText16<200, false>::validate(value);
    destination.assign(value);
  }

  static void discoverBase(std::string_view root, FixedText<200> &base) {
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
