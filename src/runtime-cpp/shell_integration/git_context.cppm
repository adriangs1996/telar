module;
#include <limits.h>

export module telar.runtime.shell_integration.git_context;

import std;

export import telar.git;
export import telar.client.protocol;
export import telar.runtime.platform.request_worker;
import telar.base.memory;
import telar.base.text;

// The git context of integrated shells: after each command, the repository their working
// directory is in, read natively on a worker so a large work tree never stalls the runtime.
export namespace telar::runtime {

struct ShellGitRequest {
  std::uint64_t pane = 0;
  std::uint64_t generation = 0;
  FixedText<PATH_MAX> directory;
};

struct ShellGitSummary {
  bool repository = false;
  bool detached = false;
  FixedText<256> branch;
  bool divergence_known = false;
  std::uint32_t ahead = 0;
  std::uint32_t behind = 0;
  bool changes_known = false;
  std::uint32_t staged = 0;
  std::uint32_t unstaged = 0;
  std::uint32_t conflicted = 0;

  inline bool operator==(const ShellGitSummary &other) const noexcept {
    return repository == other.repository && detached == other.detached && branch.view() == other.branch.view() && divergence_known == other.divergence_known && ahead == other.ahead && behind == other.behind && changes_known == other.changes_known && staged == other.staged && unstaged == other.unstaged && conflicted == other.conflicted;
  }

  inline PaneGit message(std::uint64_t pane) const noexcept {
    return PaneGit{.pane_id = pane, .repository = repository, .detached = detached, .branch = branch.view(), .divergence_known = divergence_known, .ahead = ahead, .behind = behind, .changes_known = changes_known, .staged = staged, .unstaged = unstaged, .conflicted = conflicted};
  }
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

  inline ShellGitReader()
      : reader_(memory_) {}

  inline Result observe(const Request &request) noexcept {
    Result result{.pane = request.pane, .generation = request.generation, .summary = {}};
    const auto &status = reader_.read(request.directory.view());
    auto &summary = result.summary;
    summary.repository = status.repository == git::RepositoryState::ready;
    if (!summary.repository) {
      return result;
    }
    summary.detached = status.head == git::HeadState::detached;
    if (summary.detached) {
      std::array<char, 2 * git::maximum_hash_size> digits{};
      summary.branch.assign(status.head_id.hex(digits, 7));
    } else {
      summary.branch.assign(std::string_view{status.branch}.substr(0, 255));
    }
    summary.divergence_known = status.divergence == git::Accuracy::exact;
    summary.ahead = status.ahead;
    summary.behind = status.behind;
    summary.changes_known = status.staged == git::Accuracy::exact && status.unstaged == git::Accuracy::exact;
    const auto &changes = status.changes;
    summary.staged = changes.staged_added + changes.staged_modified + changes.staged_deleted;
    summary.unstaged = changes.unstaged_modified + changes.unstaged_deleted + changes.intent_to_add;
    summary.conflicted = changes.conflicted;
    return result;
  }

  inline void stop() noexcept {}

private:
  SystemAllocator memory_;
  git::StatusReader<SystemAllocator> reader_;
};

// One read at a time: while one runs, the latest request of each other pane waits.
class ShellGitService {
public:
  inline ShellGitService()
      : worker_(std::in_place) {}

  inline void request(std::uint64_t pane, std::uint64_t generation, std::string_view directory) {
    if (directory.empty() || directory.front() != '/' || directory.size() >= PATH_MAX) {
      return;
    }
    ShellGitRequest next{.pane = pane, .generation = generation, .directory = {}};
    next.directory.assign(directory);
    std::erase_if(waiting_, [&](const ShellGitRequest &entry) { return entry.pane == pane; });
    if (!busy_ && worker_.submit(next)) {
      busy_ = true;
      return;
    }
    waiting_.push_back(next);
  }

  template <typename Consumer>
  inline void collect(Consumer &&consume) {
    worker_.collect([&](const ShellGitResult &result) {
      busy_ = false;
      consume(result);
    });
    while (!busy_ && !waiting_.empty()) {
      const auto next = waiting_.front();
      waiting_.erase(waiting_.begin());
      busy_ = worker_.submit(next);
    }
  }

  inline int descriptor() const noexcept {
    return worker_.descriptor();
  }

private:
  ObservationWorker<ShellGitReader> worker_;
  std::vector<ShellGitRequest> waiting_;
  bool busy_ = false;
};

}
