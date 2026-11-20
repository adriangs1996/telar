module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.workspaces.worktrees.git_probe;

import std;
import telar.sys.posix;
import telar.base.text;
import telar.base.text.utf8;
import telar.wire.vocabulary;
import telar.git.checkout;
import telar.platform.primitives;
import telar.base.ds;

namespace telar::runtime {

  GitBaseDistance::GitBaseDistance(ConcurrentMemory& memory, const std::atomic<bool>& cancelled) noexcept
      : memory_(memory),
        cancelled_(cancelled) {}

  template <std::size_t Capacity>
  FixedText<Capacity> GitBaseDistance::line(std::string_view root, Clock::time_point deadline, std::initializer_list<std::string_view> arguments) {
    GitRepository git{memory_, root, deadline, cancelled_};
    constexpr std::size_t maximum_output = 4096;
    const auto output = git.run(arguments, false, maximum_output);
    const auto trimmed = trimText(output, " \r\n");
    if (trimmed.size() > Capacity) {
      reject();
    }

    FixedText<Capacity> result;

    result.assign(trimmed);
    return result;
  }

  GitDistance GitBaseDistance::read(std::string_view root, std::string_view base, Clock::time_point deadline) {
    if (base.empty() || base.starts_with('-')) {
      reject();
    }

    const auto ancestor = line<64>(root, deadline, {"merge-base", base, "HEAD"});
    const auto difference = line<4096>(root, deadline, {"diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all", "--shortstat", ancestor.view(), "--"});
    GitDistance result;

    parseDiff(difference.view(), result);
    ds::String<ConcurrentMemory> range{memory_, ancestor.view()};

    range.append("..HEAD");
    const auto count = line<32>(root, deadline, {"rev-list", "--count", range, "--"});
    const auto text = count.view();
    const auto ahead = parseExact<decltype(result.ahead)>(text);
    if (!ahead) {
      reject();
    }

    result.ahead = *ahead;

    return result;
  }

  void GitBaseDistance::parseDiff(std::string_view output, GitDistance& result) noexcept {
    while (!output.empty()) {
      const auto delimiter = output.find(',');
      const auto part = trimText(textPrefix(output, delimiter), " \n");

      output = delimiter == std::string_view::npos ? std::string_view{} : textAfter(output, delimiter + 1);
      const auto separator = part.find(' ');
      if (separator == std::string_view::npos) {
        continue;
      }

      const auto value = parseExact<std::uint32_t>(textPrefix(part, separator));
      if (!value) {
        continue;
      }

      const auto label = textAfter(part, separator + 1);
      if (label.starts_with("file")) {
        result.files = *value;
      } else if (label.starts_with("insertion")) {
        result.added = *value;
      } else if (label.starts_with("deletion")) {
        result.removed = *value;
      }
    }
  }

  void GitBaseDistance::reject() {
    throw RequestError{FailureCode::invalid_request, "Git distance unavailable"};
  }

  WorktreeDetectionResult WorktreeDetectionProbe::observe(const Request& request) noexcept { // NOLINT(bugprone-exception-escape): assign throws only past the capacity the validation keeps the branch within
    TELAR_TRACE("worktrees.detect");
    Result result{.pane = request.pane, .generation = request.generation, .cwd_revision = request.cwd_revision};
    LinkedWorktree reader{};
    if (const auto found = reader.find(request.cwd.view())) {
      try {
        Text16<probed_path_bytes, false>::validate(textPrefix(request.cwd.view(), found->root_length));
        DisplayText16<probed_branch_bytes, false>::validate(found->branch);
        result.branch.assign(found->branch);
        result.root_length = found->root_length;
      } catch (const EncodingError&) { // NOLINT(bugprone-empty-catch): a checkout whose root or branch is not display text is reported as none
      }
    }

    return result;
  }

  void WorktreeDetectionProbe::stop() noexcept {}

  WorktreeGitProbe::WorktreeGitProbe(ConcurrentMemory& memory)
      : memory_(memory),
        status_(memory),
        distance_(memory, cancelled_) {}

  void WorktreeGitProbe::stop() noexcept {
    cancelled_ = true;
    status_.stop();
  }

  WorktreeProbeResult WorktreeGitProbe::observe(const Request& request) noexcept {
    TELAR_TRACE("worktrees.gitProbe");
    Result result{.identity = request.identity};

    try {
      const ds::String<ConcurrentMemory> path{memory_, request.path.view()};
      struct stat filesystem_status{};
      if (::stat(path.data(), &filesystem_status) != 0 || !S_ISDIR(filesystem_status.st_mode)) {
        return result;
      }

      result.present = true;
      const auto status = status_.read(request.path.view());
      if (status.present) {
        try {
          assignBranch(result.branch, status.branch.view());
        } catch (const EncodingError&) { // NOLINT(bugprone-empty-catch): a branch that is not display text is reported as none
        }
      }

      result.timeout = status.timed_out ? GitProbeTimeout::status : GitProbeTimeout::none;
      result.base = request.base;
      if (result.base.view().empty()) {
        try {
          discoverBase(request.path.view(), result.base);
        } catch (const EncodingError&) { // NOLINT(bugprone-empty-catch): a base that is not display text stays unknown
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
      } catch (const RequestError& error) {
        if (error.code() == FailureCode::resource_limit && std::chrono::steady_clock::now() >= deadline) {
          result.timeout = GitProbeTimeout::distance;
        }
      }
    } catch (...) { // NOLINT(bugprone-empty-catch): any other failure reports what the probe learned before it
    }

    return result;
  }

  void WorktreeGitProbe::assignBranch(FixedText<probed_branch_bytes>& destination, std::string_view value) {
    DisplayText16<probed_branch_bytes, false>::validate(value);
    destination.assign(value);
  }

  void WorktreeGitProbe::discoverBase(std::string_view root, FixedText<probed_branch_bytes>& base) {
    LinkedWorktree reader{};
    if (const auto branch = reader.mainBranch(root)) {
      assignBranch(base, *branch);
    }
  }

}
