#pragma once

#include "telar_base/memory/allocator.hpp"
#include "telar_base/text/json.hpp"
#include "telar_platform/error.hpp"
#include <cstdio>
#include <spawn.h>
#include <sys/wait.h>

extern char **environ;

namespace telar::runtime::proxy_trust {

template <typename Executor>
concept TrustCommandExecutor = requires(Executor &executor, std::span<const std::string_view> arguments) {
  { executor.run(arguments) } -> std::same_as<void>;
};

template <Allocator Memory>
class SystemCommand {
public:
  explicit SystemCommand(Memory &memory, FILE *output) noexcept : memory_(memory), output_(output) {}

  void run(std::span<const std::string_view> arguments) {
    Vector<String<Memory>, Memory> owned{AllocatorRef<String<Memory>, Memory>{memory_}};
    Vector<char *, Memory> pointers{AllocatorRef<char *, Memory>{memory_}};
    String<Memory> line{"telar proxy trust: exec", AllocatorRef<char, Memory>{memory_}};
    owned.reserve(arguments.size());
    pointers.reserve(arguments.size() + 1);
    for (const auto argument : arguments) {
      if (argument.contains('\0')) {
        throw std::invalid_argument{"Invalid proxy trust command argument"};
      }

      owned.emplace_back(argument, AllocatorRef<char, Memory>{memory_});
      line += ' ';
      appendJsonString(line, argument);
    }

    line += '\n';
    if (std::fwrite(line.data(), 1, line.size(), output_) != line.size() || std::fflush(output_) != 0) {
      throw SystemError{"Print proxy trust command", EIO};
    }
    for (auto &argument : owned) {
      pointers.push_back(argument.data());
    }
    pointers.push_back(nullptr);

    pid_t child;
    if (const int error = ::posix_spawn(&child, pointers.front(), nullptr, nullptr, pointers.data(), environ)) {
      throw SystemError{"Start proxy trust command", error};
    }

    int status;
    pid_t waited;
    do {
      waited = ::waitpid(child, &status, 0);
    } while (waited < 0 && errno == EINTR);
    if (waited < 0) {
      throw SystemError{"Wait for proxy trust command"};
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
      throw SystemError{"Proxy trust command failed", EIO};
    }
  }

private:
  Memory &memory_;
  FILE *output_;
};

template <Allocator Memory>
SystemCommand(Memory &memory, FILE *output) -> SystemCommand<Memory>;

}
