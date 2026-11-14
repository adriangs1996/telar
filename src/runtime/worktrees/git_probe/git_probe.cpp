module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.worktrees.git_probe;

import std;
import telar.sys.posix;
import telar.base.diagnostics;
import telar.base.text;
import telar.base.text.utf8;
import telar.wire.vocabulary;
import telar.git.checkout;

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
    String<ConcurrentMemory> range{ancestor.view(), AllocatorRef<char, ConcurrentMemory>{memory_}};

    range += "..HEAD";
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
      const auto part = trimText(output.substr(0, delimiter), " \n");

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

  void GitBaseDistance::reject() {
    throw RequestError{FailureCode::invalid_request, "Git distance unavailable"};
  }

  WorktreeDetectionResult WorktreeDetectionProbe::observe(const Request& request) noexcept {
    TELAR_TRACE("worktrees.detect");
    Result result{.pane = request.pane, .generation = request.generation, .cwd_revision = request.cwd_revision};
    LinkedWorktree reader;
    if (const auto found = reader.find(request.cwd.view())) {
      try {
        Text16<4096, false>::validate(request.cwd.view().substr(0, found->root_length));
        DisplayText16<200, false>::validate(found->branch);
        result.branch.assign(found->branch);
        result.root_length = found->root_length;
      } catch (const EncodingError&) {
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
      String<ConcurrentMemory> path{request.path.view(), AllocatorRef<char, ConcurrentMemory>{memory_}};
      struct stat filesystem_status{};
      if (::stat(path.c_str(), &filesystem_status) != 0 || !S_ISDIR(filesystem_status.st_mode)) {
        return result;
      }

      result.present = true;
      const auto status = status_.read(request.path.view());
      if (status.present) {
        try {
          assignBranch(result.branch, status.branch.view());
        } catch (const EncodingError&) {
        }
      }

      result.timeout = status.timed_out ? GitProbeTimeout::status : GitProbeTimeout::none;
      result.base = request.base;
      if (result.base.view().empty()) {
        try {
          discoverBase(request.path.view(), result.base);
        } catch (const EncodingError&) {
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
    } catch (...) {
    }

    return result;
  }

  void WorktreeGitProbe::assignBranch(FixedText<200>& destination, std::string_view value) {
    DisplayText16<200, false>::validate(value);
    destination.assign(value);
  }

  void WorktreeGitProbe::discoverBase(std::string_view root, FixedText<200>& base) {
    LinkedWorktree reader;
    if (const auto branch = reader.mainBranch(root)) {
      assignBranch(base, *branch);
    }
  }

}
