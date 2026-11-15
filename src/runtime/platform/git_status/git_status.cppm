module;
#include "tbc/annotations.hpp"

export module telar.runtime.platform.git_status;

import std;

export import telar.platform.process;
import telar.base.diagnostics;
import telar.vocabulary;
import telar.git.checkout;
import telar.platform.primitives;
import telar.base.memory.allocators;
import telar.base.memory.containers;

// Interface: platform/git_repository.cppm
export {
  namespace telar::runtime {

    class GitRepository {
    public:
      using Clock = std::chrono::steady_clock;

      explicit GitRepository(ConcurrentMemory& memory, std::string_view root, Clock::time_point deadline, const std::atomic<bool>& cancelled);

      std::string_view run(std::initializer_list<std::string_view> arguments, bool retain_prefix = false, std::size_t maximum_bytes = maximum_output);

      int execute(std::initializer_list<std::string_view> arguments, bool retain_prefix = false);

      // Generic over the caller's consumer, so it stays a template here.
      template <typename Consumer>
      TBC_GENERIC inline int stream(std::initializer_list<std::string_view> arguments, Consumer&& consume, Clock::time_point deadline = Clock::time_point::max()) {
        return withCommand(arguments, [&](auto& command) {
          return output_.stream(command, deadline, consume);
        });
      }

    private:
      // Generic over the caller's operation, so it stays a template here.
      template <typename Operation>
      TBC_GENERIC inline int withCommand(std::initializer_list<std::string_view> arguments, Operation&& operation) {
        return git_.with(arguments, operation);
      }

      [[noreturn]] static void reject();

      static constexpr std::size_t maximum_output = 64 * 1024;
      Clock::time_point deadline_;
      CommandOutput<ConcurrentMemory> output_;
      HardenedGit<ConcurrentMemory> git_;
    };

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

    class GitStatusReader {
    public:
      using Clock = std::chrono::steady_clock;

      explicit GitStatusReader(ConcurrentMemory& memory) noexcept;

      GitStatus read(std::string_view root) noexcept;

      void stop() noexcept;

    private:
      ConcurrentMemory& memory_;
      std::atomic<bool> cancelled_{false};
    };

  }
}
