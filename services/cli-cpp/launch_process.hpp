#pragma once

#include "command_error.hpp"

#include "telar_platform/error.hpp"
#include "telar_platform/file_descriptor.hpp"
#include "telar_platform/write_descriptor.hpp"
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <optional>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <string>
#include <sys/wait.h>
#include <thread>
#include <vector>

extern char **environ;

namespace telar::runtime::cli::launch {

inline constexpr int ssh_failure = 255;
inline constexpr std::size_t output_limit = 256 * 1024;
inline constexpr std::size_t error_limit = 64 * 1024;
inline constexpr auto poll_interval = std::chrono::milliseconds{10};

inline std::vector<char *> pointers(const std::vector<std::string> &arguments) {
  std::vector<char *> result;
  result.reserve(arguments.size() + 1);
  for (const auto &argument : arguments) {
    result.push_back(const_cast<char *>(argument.c_str()));
  }

  result.push_back(nullptr);
  return result;
}

[[noreturn]] inline void replace(const std::vector<std::string> &arguments) {
  const auto argv = pointers(arguments);
  ::execvp(argv.front(), argv.data());
  throw CommandError{errno == ENOENT ? "FileNotFound" : errno == EACCES ? "AccessDenied"
                                                                        : "Unexpected"};
}

inline pid_t spawn(const std::vector<std::string> &arguments, posix_spawn_file_actions_t *actions) {
  const auto argv = pointers(arguments);
  posix_spawnattr_t attributes;
  ::posix_spawnattr_init(&attributes);
  sigset_t signals;
  sigemptyset(&signals);
  ::posix_spawnattr_setsigmask(&attributes, &signals);
  short flags = POSIX_SPAWN_SETSIGMASK;
#if defined(POSIX_SPAWN_CLOEXEC_DEFAULT)
  flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
  ::posix_spawnattr_setflags(&attributes, flags);
  posix_spawn_file_actions_t inherited;
  const bool inherit_streams = actions == nullptr;
  if (inherit_streams) {
    ::posix_spawn_file_actions_init(&inherited);
#if defined(__APPLE__)
    for (int descriptor = STDIN_FILENO; descriptor <= STDERR_FILENO; ++descriptor) {
      ::posix_spawn_file_actions_addinherit_np(&inherited, descriptor);
    }
#endif
    actions = &inherited;
  }

  pid_t process = -1;
  const auto failure = ::posix_spawnp(&process, argv.front(), actions, &attributes, argv.data(), environ);
  ::posix_spawnattr_destroy(&attributes);
  if (inherit_streams) {
    ::posix_spawn_file_actions_destroy(&inherited);
  }

  if (failure != 0) {
    throw SystemError{"Start child process", failure};
  }

  return process;
}

inline int wait(pid_t process) {
  int status = 0;
  while (::waitpid(process, &status, 0) < 0) {
    if (errno != EINTR) {
      throw SystemError{"Wait for child process"};
    }
  }

  return WIFEXITED(status) ? WEXITSTATUS(status) : ssh_failure;
}

inline int inherit(const std::vector<std::string> &arguments) {
  return wait(spawn(arguments, nullptr));
}

struct Output {
  int status = ssh_failure;
  std::string out;
  std::string err;
  std::size_t dropped = 0;

  std::string_view errorLine() const {
    const auto end = err.find_last_not_of(" \r\n");
    if (end == std::string::npos) {
      return {};
    }

    const auto start = err.rfind('\n', end);
    return std::string_view{err}.substr(start == std::string::npos ? 0 : start + 1, end + 1 - (start == std::string::npos ? 0 : start + 1));
  }
};

struct Pipe {
  FileDescriptor read;
  FileDescriptor write;

  Pipe() {
    std::array<int, 2> ends;
    if (::pipe(ends.data()) != 0) {
      throw SystemError{"Create process pipe"};
    }

    read.reset(ends[0]);
    write.reset(ends[1]);
    ::fcntl(read.get(), F_SETFD, FD_CLOEXEC);
    ::fcntl(write.get(), F_SETFD, FD_CLOEXEC);
    ::fcntl(read.get(), F_SETFL, O_NONBLOCK);
  }
};

// The input is an unlinked owner-only file, so arbitrary script/binary sizes
// cannot deadlock against a child filling either output pipe.
inline Output capture(const std::vector<std::string> &arguments, int input, std::chrono::seconds timeout) {
  Pipe out;
  Pipe err;
  posix_spawn_file_actions_t actions;
  ::posix_spawn_file_actions_init(&actions);
  if (input < 0) {
    ::posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
  } else {
    ::posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO);
  }

  ::posix_spawn_file_actions_adddup2(&actions, out.write.get(), STDOUT_FILENO);
  ::posix_spawn_file_actions_adddup2(&actions, err.write.get(), STDERR_FILENO);
  pid_t process;
  try {
    process = spawn(arguments, &actions);
  } catch (...) {
    ::posix_spawn_file_actions_destroy(&actions);
    throw;
  }

  ::posix_spawn_file_actions_destroy(&actions);
  out.write.reset();
  err.write.reset();
  Output result;
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  std::array<pollfd, 2> descriptors{{{out.read.get(), POLLIN, 0}, {err.read.get(), POLLIN, 0}}};
  const std::array<std::string *, 2> buffers{&result.out, &result.err};
  constexpr std::array limits{output_limit, error_limit};
  std::optional<int> status;
  try {
    while (!status || descriptors[0].fd >= 0 || descriptors[1].fd >= 0) {
      if (std::chrono::steady_clock::now() >= deadline) {
        throw CommandError{"Timeout"};
      }

      const auto ready = ::poll(descriptors.data(), descriptors.size(), static_cast<int>(poll_interval.count()));
      if (ready < 0 && errno != EINTR) {
        throw SystemError{"Read child process output"};
      }

      for (std::size_t index = 0; index < descriptors.size(); ++index) {
        if (descriptors[index].fd < 0 || descriptors[index].revents == 0) {
          continue;
        }

        std::array<char, 16 * 1024> chunk;
        const auto count = ::read(descriptors[index].fd, chunk.data(), chunk.size());
        if (count == 0) {
          descriptors[index].fd = -1;
        } else if (count > 0) {
          auto &buffer = *buffers[index];
          buffer.append(chunk.data(), static_cast<std::size_t>(count));
          if (buffer.size() > limits[index]) {
            const auto dropped = buffer.size() - limits[index];
            if (index == 0) {
              result.dropped += dropped;
            }

            buffer.erase(0, dropped);
          }
        } else if (errno != EINTR && errno != EAGAIN) {
          throw SystemError{"Read child process stream"};
        }
      }

      int exited = 0;
      if (!status && ::waitpid(process, &exited, WNOHANG) == process) {
        status = WIFEXITED(exited) ? WEXITSTATUS(exited) : ssh_failure;
      }
    }
  } catch (...) {
    if (!status) {
      ::kill(process, SIGKILL);
      wait(process);
    }

    throw;
  }

  result.status = *status;
  return result;
}

inline Output captureBytes(const std::vector<std::string> &arguments, std::string_view input, std::chrono::seconds timeout) {
  const auto *temporary = std::getenv("TMPDIR");
  std::string name = std::string{temporary && *temporary ? temporary : "/tmp"} + "/telar-script-XXXXXX";
  FileDescriptor file{::mkstemp(name.data())};
  if (!file) {
    throw SystemError{"Create private process input"};
  }

  ::unlink(name.c_str());
  ::fcntl(file.get(), F_SETFD, FD_CLOEXEC);
  const auto failure = writeDescriptor(file.get(), {reinterpret_cast<const std::uint8_t *>(input.data()), input.size()});
  if (failure != 0 || ::lseek(file.get(), 0, SEEK_SET) < 0) {
    throw SystemError{"Write process input", failure != 0 ? failure : errno};
  }

  return capture(arguments, file.get(), timeout);
}

inline std::string quote(std::string_view value) {
  std::string result = "'";
  for (const auto byte : value) {
    result += byte == '\'' ? "'\\''" : std::string(1, byte);
  }

  return result + "'";
}

}
