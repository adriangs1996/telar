module;
#include "tbc/hot_path.hpp"

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

      explicit GitRepository(Memory& memory, std::string_view root, Clock::time_point deadline, const std::atomic<bool>& cancelled);

      std::string_view run(std::initializer_list<std::string_view> arguments, bool retain_prefix = false, std::size_t maximum_bytes = maximum_output);

      int execute(std::initializer_list<std::string_view> arguments, bool retain_prefix = false);

      // Generic over the caller's consumer, so it stays a template here.
      template <typename Consumer>
      TBC_HOT_PATH inline int stream(std::initializer_list<std::string_view> arguments, Consumer&& consume, Clock::time_point deadline = Clock::time_point::max()) {
        return withCommand(arguments, [&](auto& command) {
          return output_.stream(command, deadline, consume);
        });
      }

    private:
      // Generic over the caller's operation, so it stays a template here.
      template <typename Operation>
      TBC_HOT_PATH inline int withCommand(std::initializer_list<std::string_view> arguments, Operation&& operation) {
        return git_.with(arguments, operation);
      }

      [[noreturn]] static void reject();

      static constexpr std::size_t maximum_output = 64 * 1024;
      Clock::time_point deadline_;
      CommandOutput<Memory> output_;
      HardenedGit<Memory> git_;
    };

    template <Allocator Memory>
    GitRepository(Memory& memory, std::string_view root, typename GitRepository<Memory>::Clock::time_point deadline, const std::atomic<bool>& cancelled) -> GitRepository<Memory>;

    extern template class GitRepository<ConcurrentMemory>;

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

      explicit GitStatusReader(Memory& memory) noexcept;

      GitStatus read(std::string_view root) noexcept;

      void stop() noexcept;

    private:
      Memory& memory_;
      std::atomic<bool> cancelled_{false};
    };

    extern template class GitStatusReader<ConcurrentMemory>;

  }
}
