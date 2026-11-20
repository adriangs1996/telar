module telar.runtime.shell_integration.git_context;

import std;
import telar.sys.posix;
import telar.base.ds;

namespace telar::runtime {

  PaneGit ShellGitSummary::message(std::uint64_t pane) const noexcept {
    return PaneGit{.pane_id = pane, .repository = repository, .detached = detached, .branch = branch.view(), .divergence_known = divergence_known, .ahead = ahead, .behind = behind, .changes_known = changes_known, .staged = staged, .unstaged = unstaged, .conflicted = conflicted};
  }

  ShellGitReader::ShellGitReader()
      : reader_(erased_) {}

  ShellGitReader::Result ShellGitReader::observe(const Request& request) noexcept { // NOLINT(bugprone-exception-escape): assign throws only past its capacity, which the hash's digits and the cut branch never reach
    Result result{.pane = request.pane, .generation = request.generation, .summary = {}};
    const auto& status = reader_.read(request.directory.view());
    auto& summary = result.summary;

    summary.repository = status.repository == git::RepositoryState::ready;
    if (!summary.repository) {
      return result;
    }

    summary.detached = status.head == git::HeadState::detached;
    if (summary.detached) {
      // As git abbreviates a commit.
      constexpr std::size_t short_hash_digits = 7;
      ds::Array<char, 2 * git::maximum_hash_size> digits{};

      summary.branch.assign(status.head_id.hex(digits.viewMut(), short_hash_digits));
    } else {
      summary.branch.assign(std::string_view{status.branch}.substr(0, ShellGitSummary::branch_bytes - 1));
    }

    summary.divergence_known = status.divergence == git::Accuracy::exact;
    summary.ahead = status.ahead;
    summary.behind = status.behind;
    summary.changes_known = status.staged == git::Accuracy::exact && status.unstaged == git::Accuracy::exact;
    const auto& changes = status.changes;

    summary.staged = changes.staged_added + changes.staged_modified + changes.staged_deleted;
    summary.unstaged = changes.unstaged_modified + changes.unstaged_deleted + changes.intent_to_add;
    summary.conflicted = changes.conflicted;
    return result;
  }

  void ShellGitReader::stop() noexcept {}

  ShellGitService::ShellGitService(ConcurrentMemory& memory)
      : worker_(std::in_place),
        queue_(memory) {}

  void ShellGitService::request(std::uint64_t pane, std::uint64_t generation, std::string_view directory) {
    if (directory.empty() || directory.front() != '/' || directory.size() >= PATH_MAX) {
      return;
    }

    ShellGitRequest next{.pane = pane, .generation = generation, .directory = {}};

    next.directory.assign(directory);
    queue_.dropWaiting([&](const ShellGitRequest& entry) {
      return entry.pane == pane;
    });

    queue_.request(worker_, next);
  }

  int ShellGitService::descriptor() const noexcept {
    return worker_.descriptor();
  }

}
