module telar.runtime.platform.git_status;

import telar.vocabulary;

namespace telar::runtime {

  GitRepository::GitRepository(ConcurrentMemory& memory, std::string_view root, Clock::time_point deadline, const std::atomic<bool>& cancelled)
      : deadline_(deadline),
        output_(memory, maximum_output, &cancelled),
        git_(memory, root) {
    git_.inspect([&](Command<ConcurrentMemory>& command) {
      return std::pair{output_.run(command, deadline_), output_.text()};
    },
        [] {
          reject();
        });
  }

  std::string_view GitRepository::run(std::initializer_list<std::string_view> arguments, bool retain_prefix, std::size_t maximum_bytes) {
    if (execute(arguments, retain_prefix) != 0) {
      reject();
    }

    auto text = output_.text();
    if (text.size() > maximum_bytes) {
      reject();
    }

    while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) {
      text.remove_suffix(1);
    }

    return text;
  }

  int GitRepository::execute(std::initializer_list<std::string_view> arguments, bool retain_prefix) {
    return withCommand(arguments, [&](auto& command) {
      return output_.run(command, deadline_, retain_prefix);
    });
  }

  void GitRepository::reject() {
    throw RequestError{FailureCode::invalid_request, "Git observation unavailable"};
  }

  GitStatusReader::GitStatusReader(ConcurrentMemory& memory) noexcept
      : memory_(memory) {}

  GitStatus GitStatusReader::read(std::string_view root) noexcept {
    GitStatus result;
    GitHead head; // NOLINT(cppcoreguidelines-pro-type-member-init): read writes the path and the HEAD bytes it reads, so zeroing 8 KiB per status read is work no read needs
    const auto branch = head.read(root);
    if (!branch) {
      return result;
    }

    result.present = true;
    const auto deadline = Clock::now() + git_status_timeout;

    try {
      // The branch is a part of the HEAD that GitHead reads, which fits the branch's capacity.
      result.branch.assign(*branch);

      GitRepository git{memory_, root, deadline, cancelled_};
      bool printed = false;
      const auto status = git.stream({"status", "--porcelain", "--no-renames", "--ignore-submodules=all"}, [&](std::span<const Byte> bytes) {
        printed |= !bytes.empty();
        return true;
      },
          deadline);
      if (status == 0) {
        result.dirty = printed;
      }
    } catch (const RequestError& error) {
      result.timed_out = error.code() == FailureCode::resource_limit && Clock::now() >= deadline;
    } catch (...) { // NOLINT(bugprone-empty-catch): any other failure of git leaves the status without its dirty state
    }

    return result;
  }

  void GitStatusReader::stop() noexcept {
    cancelled_ = true;
  }

}
