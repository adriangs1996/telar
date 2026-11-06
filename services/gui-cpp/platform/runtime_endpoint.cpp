module;

#include "telar_platform/process_environment.h"

#include <string>
#include <span>
#include <string_view>
#include <vector>
#include <array>
#include <cstddef>
#include <variant>
#include "telar_client/serializers/telar_serializer.hpp"
#include <algorithm>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdexcept>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif

module telar.gui.platform.profile_file;

import telar.gui.platform.login_shell;
import telar.client;


#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif


namespace telar::gui::platform {
namespace {
using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;
// A slow login shell, plus telar's own wait for a runtime it has to start.
constexpr auto answer_timeout = 30s;
constexpr auto exit_poll_interval = 1ms;
// The socket path and the schema, one per line.
constexpr std::size_t answer_limit = PATH_MAX + 1 + std::tuple_size_v<telar::SchemaId> + 1;
// What a failure keeps of telar's standard error.
constexpr std::size_t error_limit = 4096;

struct Pipe {
  int read = -1;
  int write = -1;

  Pipe() {
    std::array<int, 2> ends{};

    if (::pipe(ends.data()) != 0) {
      throw std::runtime_error(std::string("Cannot create a pipe: ") + std::strerror(errno));
    }

    read = ends[0];
    write = ends[1];
    ::fcntl(read, F_SETFD, FD_CLOEXEC);
    ::fcntl(write, F_SETFD, FD_CLOEXEC);
  }

  ~Pipe() {
    closeRead();
    closeWrite();
  }

  Pipe(const Pipe &) = delete;
  Pipe &operator=(const Pipe &) = delete;

  void closeRead() {
    if (read >= 0) {
      ::close(read);
      read = -1;
    }
  }

  void closeWrite() {
    if (write >= 0) {
      ::close(write);
      write = -1;
    }
  }
};

struct Answer {
  std::string output;
  std::string errors;
  int status = 0;
  bool timed_out = false;
};

std::filesystem::path executable() {
  std::error_code error;
#if defined(__APPLE__)
  std::array<char, PATH_MAX> buffer{};
  auto size = static_cast<std::uint32_t>(buffer.size());

  if (_NSGetExecutablePath(buffer.data(), &size) != 0) {
    return {};
  }

  return std::filesystem::canonical(buffer.data(), error);
#else
  return std::filesystem::read_symlink("/proc/self/exe", error);
#endif
}

// The telar installed beside this executable, or in the application bundle that holds it;
// otherwise the one the login shell finds on PATH, as a terminal would.
std::string telarProgram() {
  const auto directory = executable().parent_path();

  if (directory.empty()) {
    return "telar";
  }

  for (const auto &candidate :
       {directory / "telar", directory / ".." / "Resources" / "bin" / "telar"}) {
    struct stat info{};

    if (::stat(candidate.c_str(), &info) == 0 && S_ISREG(info.st_mode) &&
        ::access(candidate.c_str(), X_OK) == 0) {
      return candidate.lexically_normal().string();
    }
  }

  return "telar";
}

pid_t spawn(const std::vector<std::string> &arguments, const Pipe &output, const Pipe &errors) {
  std::vector<char *> argv;
  for (const auto &argument : arguments) {
    argv.push_back(const_cast<char *>(argument.c_str()));
  }

  argv.push_back(nullptr);

  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
  posix_spawn_file_actions_adddup2(&actions, output.write, STDOUT_FILENO);
  posix_spawn_file_actions_adddup2(&actions, errors.write, STDERR_FILENO);

  posix_spawnattr_t attributes;
  posix_spawnattr_init(&attributes);
  short flags = 0;
#if defined(__linux__)
  // The compositor blocks session signals before starting any worker. A new
  // runtime and its login shell must retain normal signal delivery.
  sigset_t mask;
  sigemptyset(&mask);
  posix_spawnattr_setsigmask(&attributes, &mask);
  flags |= POSIX_SPAWN_SETSIGMASK;
#endif
#if defined(POSIX_SPAWN_CLOEXEC_DEFAULT)
  // Only the three standard streams reach telar, never another descriptor of this process.
  flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
  posix_spawnattr_setflags(&attributes, flags);

  pid_t child = 0;
  const int failure =
      ::posix_spawnp(&child, argv[0], &actions, &attributes, argv.data(), environ);
  posix_spawnattr_destroy(&attributes);
  posix_spawn_file_actions_destroy(&actions);

  if (failure != 0) {
    throw std::runtime_error("Cannot start " + arguments[0] + ": " + std::strerror(failure));
  }

  return child;
}

// Reads both streams until telar closes them, then waits for it to exit, all within one
// deadline; a telar still running at the deadline is killed.
Answer ask(const std::vector<std::string> &arguments) {
  Pipe output;
  Pipe errors;
  const auto child = spawn(arguments, output, errors);
  output.closeWrite();
  errors.closeWrite();

  Answer answer;
  const auto deadline = Clock::now() + answer_timeout;
  std::array<pollfd, 2> streams{{{output.read, POLLIN, 0}, {errors.read, POLLIN, 0}}};
  const std::array<std::string *, 2> buffers{&answer.output, &answer.errors};
  // One byte past the answer's limit tells an oversized answer from one that fits.
  const std::array<std::size_t, 2> limits{answer_limit + 1, error_limit};

  while (!answer.timed_out && (streams[0].fd >= 0 || streams[1].fd >= 0)) {
    const auto left = std::chrono::ceil<std::chrono::milliseconds>(deadline - Clock::now());

    if (left <= 0ms) {
      answer.timed_out = true;
      break;
    }

    if (::poll(streams.data(), streams.size(), static_cast<int>(left.count())) < 0) {
      if (errno == EINTR) {
        continue;
      }

      throw std::runtime_error(std::string("Cannot read telar's answer: ") +
                               std::strerror(errno));
    }

    for (std::size_t index = 0; index < streams.size(); ++index) {
      if (streams[index].fd < 0 || !streams[index].revents) {
        continue;
      }

      std::array<char, 4096> chunk;
      const auto count = ::read(streams[index].fd, chunk.data(), chunk.size());

      if (count < 0 && errno == EINTR) {
        continue;
      }

      if (count <= 0) {
        // poll skips negative descriptors.
        streams[index].fd = -1;
        continue;
      }

      auto &buffer = *buffers[index];
      const auto kept = std::min(static_cast<std::size_t>(count), limits[index] - buffer.size());
      buffer.append(chunk.data(), kept);
    }
  }

  while (true) {
    const auto exited = ::waitpid(child, &answer.status, WNOHANG);

    if (exited == child || (exited < 0 && errno != EINTR)) {
      break;
    }

    if (answer.timed_out || Clock::now() >= deadline) {
      answer.timed_out = true;
      ::kill(child, SIGKILL);

      while (::waitpid(child, &answer.status, 0) < 0 && errno == EINTR) {
      }

      break;
    }

    std::this_thread::sleep_for(exit_poll_interval);
  }

  return answer;
}

std::string_view trimmed(std::string_view text) {
  const auto end = text.find_last_not_of(" \t\r\n");
  return end == std::string_view::npos ? std::string_view{} : text.substr(0, end + 1);
}

// Exactly the socket path and the schema, each ending its line. Anything else, such as what a
// shell startup file prints, is refused rather than guessed around.
std::string parse(std::string_view answer) {
  const auto unreadable =
      std::runtime_error("telar answered with something other than the runtime endpoint");
  const auto end = answer.find('\n');

  if (end == std::string_view::npos) {
    throw unreadable;
  }

  const auto path = answer.substr(0, end);
  const auto schema = answer.substr(end + 1);
  const auto &expected = telar::handshake::schema_id;

  if (path.empty() || path.front() != '/' || path.size() >= sizeof(sockaddr_un::sun_path) ||
      std::ranges::any_of(path, [](unsigned char byte) {
        return byte < 0x20 || byte == 0x7f;
      })) {
    throw unreadable;
  }

  if (schema.size() != expected.size() + 1 || schema.back() != '\n' ||
      std::ranges::any_of(schema.substr(0, expected.size()), [](unsigned char byte) {
        return !std::isalnum(byte);
      })) {
    throw unreadable;
  }

  if (!std::ranges::equal(schema.substr(0, expected.size()), expected, {}, [](char byte) {
        return static_cast<telar::Byte>(byte);
      })) {
    throw std::runtime_error(
        "telar speaks wire schema " + std::string(schema.substr(0, expected.size())) +
        "; the GUI speaks " + std::string(expected.begin(), expected.end()) +
        ". Update one of them");
  }

  return std::string(path);
}
}

namespace runtime_endpoint {
std::string program() {
  return telarProgram();
}

std::string resolve() {
  const auto shell = login_shell::path();
  const auto program = telarProgram();
  std::vector<std::string> arguments;

  if (const char *line = login_shell::script(shell)) {
    arguments = {shell, "-l", "-c", line, program, "server", "endpoint"};
  } else {
    arguments = {program, "server", "endpoint"};
  }

  const auto answer = ask(arguments);

  if (answer.timed_out) {
    throw std::runtime_error("telar did not report the runtime endpoint in time");
  }

  if (!WIFEXITED(answer.status) || WEXITSTATUS(answer.status) != 0) {
    throw std::runtime_error("`telar server endpoint` failed: " +
                             std::string(trimmed(answer.errors)));
  }

  return parse(answer.output);
}
}
}
