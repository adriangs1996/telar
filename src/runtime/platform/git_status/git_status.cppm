module;
#include <cstdio>
#include <cstdlib>
#include <new>

#include <cassert>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits.h>
#include <poll.h>
#include <sys/types.h>
#include <sys/wait.h>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

export module telar.runtime.platform.git_status;

import std;

export import telar.platform.process;
import telar.base.diagnostics;
import telar.vocabulary;
import telar.git.checkout;
import telar.platform.primitives;

// Interface: platform/git_repository.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class GitRepository {
    public:
      using Clock = std::chrono::steady_clock;

      inline explicit GitRepository(Memory& memory, std::string_view root, Clock::time_point deadline, const std::atomic<bool>& cancelled)
          : deadline_(deadline),
            output_(memory, maximum_output, &cancelled),
            git_(memory, root) {
        git_.inspect([&](Command<Memory>& command) {
          return std::pair{output_.run(command, deadline_), output_.text()};
        },
            [] {
              reject();
            });
      }

      inline std::string_view run(std::initializer_list<std::string_view> arguments, bool retain_prefix = false, std::size_t maximum_bytes = maximum_output) {
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

      inline int execute(std::initializer_list<std::string_view> arguments, bool retain_prefix = false) {
        return withCommand(arguments, [&](auto& command) {
          return output_.run(command, deadline_, retain_prefix);
        });
      }

      template <typename Consumer>
      inline int stream(std::initializer_list<std::string_view> arguments, Consumer&& consume, Clock::time_point deadline = Clock::time_point::max()) {
        return withCommand(arguments, [&](auto& command) {
          return output_.stream(command, deadline, consume);
        });
      }

    private:
      template <typename Operation>
      inline int withCommand(std::initializer_list<std::string_view> arguments, Operation&& operation) {
        return git_.with(arguments, operation);
      }

      [[noreturn]] inline static void reject() {
        throw RequestError{FailureCode::invalid_request, "Git observation unavailable"};
      }

      static constexpr std::size_t maximum_output = 64 * 1024;
      Clock::time_point deadline_;
      CommandOutput<Memory> output_;
      HardenedGit<Memory> git_;
    };

    template <Allocator Memory>
    GitRepository(Memory& memory, std::string_view root, typename GitRepository<Memory>::Clock::time_point deadline, const std::atomic<bool>& cancelled) -> GitRepository<Memory>;

  }
}

// Interface: platform/git_status.cppm
export {
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

      inline explicit GitStatusReader(Memory& memory) noexcept
          : memory_(memory) {}

      inline GitStatus read(std::string_view root) noexcept {
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
            return true;
          },
              deadline);
          if (status == 0) {
            result.dirty = printed;
          }
        } catch (const RequestError& error) {
          result.timed_out = error.code() == FailureCode::resource_limit && Clock::now() >= deadline;
        } catch (...) {
        }

        return result;
      }

      inline void stop() noexcept {
        cancelled_ = true;
      }

    private:
      Memory& memory_;
      std::atomic<bool> cancelled_{false};
    };

  }
}
