#pragma once

#include "git_repository.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_platform/git_head.hpp"

namespace telar::runtime {

inline constexpr auto git_status_timeout = std::chrono::seconds{10};

struct GitStatus {
  FixedText<4096> branch;
  std::optional<bool> dirty;
  bool present = false;
  bool timed_out = false;
};

template <ConcurrentAllocator Memory>
class GitStatusReader {
public:
  using Clock = std::chrono::steady_clock;

  explicit GitStatusReader(Memory &memory) noexcept
      : memory_(memory) {}

  GitStatus read(std::string_view root) noexcept {
    GitStatus result;
    GitHead head;
    const auto branch = head.read(root);
    if (!branch) {
      return result;
    }

    result.present = true;
    result.branch.assign(*branch);
    const auto deadline = Clock::now() + git_status_timeout;
    try {
      GitRepository git{memory_, root, deadline, cancelled_};
      bool printed = false;
      const auto status = git.stream({"status", "--porcelain", "--no-renames", "--ignore-submodules=all"}, [&](std::span<const Byte> bytes) {
        printed |= !bytes.empty();
        return true; }, deadline);
      if (status == 0) {
        result.dirty = printed;
      }
    } catch (const RequestError &error) {
      result.timed_out = error.code() == FailureCode::resource_limit && Clock::now() >= deadline;
    } catch (...) {
    }

    return result;
  }

  void stop() noexcept {
    cancelled_ = true;
  }

private:
  Memory &memory_;
  std::atomic<bool> cancelled_{false};
};

}
