module;
#include <cstdio>
#include <new>


#include <cstdint>
#include "help_texts.hpp"

#include <cerrno>
#include <cstddef>
#include <cstring>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>
#include <cstdlib>
#include <limits.h>
#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif
#include <fcntl.h>
#include <sys/stat.h>
#include <csignal>
#include <dirent.h>
#include <spawn.h>
#include <sys/wait.h>

export module telar.cli.server;

import std;

export import telar.cli.output;


export import telar.cli.runtime_observer;
export import telar.platform;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: command_error.cppm
export {
namespace telar::runtime::cli {

// Zig's uncaught execution errors use this prefix; argument errors use the
// separate help-bearing diagnostic and machine edits have their own report.
class CommandError : public std::runtime_error {
public:
  using std::runtime_error::runtime_error;
};

}
}

// Interface: help.cppm
export {
namespace telar::runtime::cli {

// What a `--help` asks about: the root when `family` is empty, a family when
// `command` is empty, otherwise one command of the family.
struct HelpTopic {
  std::string_view family;
  std::string_view command;
};

inline std::optional<std::string_view> helpText(HelpTopic topic) noexcept {
  for (const auto &entry : help_texts) {
    if (entry.family == topic.family && entry.command == topic.command) {
      return entry.text;
    }
  }

  return std::nullopt;
}

// The command a family's second word names, when its help lists it.
inline std::string_view knownCommand(Family family, std::string_view word) noexcept {
  const HelpTopic topic{.family = familyName(family), .command = word};
  return !word.empty() && helpText(topic) ? word : std::string_view{};
}

inline bool isHelpFlag(std::string_view word) noexcept {
  return word == "--help" || word == "-h";
}

// The help a command line asks for, as Zig's `help.find`: a leading flag asks for
// the root, and a flag anywhere after a family, but before `--`, for that family or
// the command its second word names. Help never starts or contacts a runtime.
inline std::optional<HelpTopic> findHelp(std::span<char *const> words) noexcept {
  if (words.empty()) {
    return std::nullopt;
  }

  if (isHelpFlag(words.front())) {
    return HelpTopic{};
  }

  const auto family = parseFamily(words.front());
  if (!family) {
    return std::nullopt;
  }

  bool asked = false;
  for (const std::string_view word : words.subspan(1)) {
    if (word == "--") {
      break;
    }

    if (isHelpFlag(word)) {
      asked = true;
      break;
    }
  }

  if (!asked) {
    return std::nullopt;
  }

  const std::string_view second = words.size() > 1 ? words[1] : "";
  return HelpTopic{.family = familyName(*family), .command = knownCommand(*family, second)};
}

// The words a usage error points at, as in "see `telar pane read --help`".
inline std::string helpReference(std::span<char *const> words) {
  const auto family = words.empty() ? std::nullopt : parseFamily(words.front());
  if (!family) {
    return "telar --help";
  }

  std::string reference{"telar "};
  reference += familyName(*family);
  const auto command = knownCommand(*family, words.size() > 1 ? words[1] : "");
  if (!command.empty()) {
    reference += ' ';
    reference += command;
  }

  reference += " --help";
  return reference;
}

}
}

// Interface: server.cppm
export {
namespace telar::runtime::cli {

inline constexpr const char *runtime_program = "telar-runtime";

inline bool connectExisting(std::optional<RuntimeConnection> &connection, const char *path) {
  try {
    connection.emplace(path);
    return true;
  } catch (const SystemError &error) {
    if (error.code() != ENOENT && error.code() != ECONNREFUSED) {
      throw;
    }

    return false;
  }
}

enum class RuntimeStart : std::uint8_t {
  listening,
  exited,
  timed_out
};

// Launches the sibling runtime where none listens and waits up to ten seconds
// for its socket.
template <Allocator Memory>
RuntimeStart startRuntime(Memory &memory, const ServerOptions &options, const RuntimePaths<Memory> &paths) {
  constexpr auto start_window = std::chrono::seconds{10};
  constexpr auto poll_interval = std::chrono::milliseconds{10};
  paths.prepareSocket();
  const auto child = launchDaemon(memory, options, paths, ExecutablePath{runtime_program});
  const auto deadline = std::chrono::steady_clock::now() + start_window;
  std::optional<RuntimeConnection> connection;
  while (!connectExisting(connection, paths.socket.c_str())) {
    int status = 0;
    if (::waitpid(child, &status, WNOHANG) == child) {
      return RuntimeStart::exited;
    }

    if (std::chrono::steady_clock::now() >= deadline) {
      return RuntimeStart::timed_out;
    }

    std::this_thread::sleep_for(poll_interval);
  }

  return RuntimeStart::listening;
}

template <Allocator Memory>
void printEndpoint(Memory &memory, const ServerOptions &options, const RuntimePaths<Memory> &paths) {
  std::optional<RuntimeConnection> connection;
  if (!connectExisting(connection, paths.socket.c_str())) {
    const auto started = startRuntime(memory, options, paths);
    if (started == RuntimeStart::exited) {
      throw SystemError{"Runtime failed to start; inspect its .runtime.start.log", ECHILD};
    }

    if (started == RuntimeStart::timed_out) {
      throw SystemError{"Runtime did not start within ten seconds", ETIMEDOUT};
    }
  }

  std::printf("%s\n", paths.socket.c_str());
  std::fwrite(handshake::schema_id.data(), 1, handshake::schema_id.size(), stdout);
  std::fputc('\n', stdout);
}

inline void stopRuntime(const char *socket) {
  std::optional<RuntimeConnection> connection;
  if (!connectExisting(connection, socket)) {
    std::puts("telar runtime is not running");
    return;
  }

  connection->requestStop();
  std::puts("telar runtime is stopping");
}

// `telar server` runs the runtime in this process: the runtime executable installed
// beside this one replaces it with the same arguments, so signals and exit status are its own.
template <Allocator Memory>
[[noreturn]] void execRuntime(Memory &memory, std::span<char *const> arguments) {
  const ExecutablePath runtime{runtime_program};
  Vector<char *, Memory> command{AllocatorRef<char *, Memory>{memory}};
  command.reserve(arguments.size() + 2);
  command.push_back(const_cast<char *>(runtime.c_str()));
  command.insert(command.end(), arguments.begin(), arguments.end());
  command.push_back(nullptr);
  ::execv(runtime.c_str(), command.data());
  throw SystemError{"Start telar-runtime, which must be installed beside telar"};
}

template <Allocator Memory>
void runServer(Memory &memory, std::span<char *const> arguments) {
  const auto options = ServerOptions::parse(arguments);
  if (options.action != ServerAction::stop && options.action != ServerAction::endpoint && options.action != ServerAction::bridge) {
    execRuntime(memory, arguments);
  }

  const ProcessEnvironment environment;
  const RuntimePaths paths{memory, options, environment};
  switch (options.action) {
  case ServerAction::stop:
    stopRuntime(paths.socket.c_str());
    return;
  case ServerAction::endpoint:
    printEndpoint(memory, options, paths);
    return;
  case ServerAction::bridge:
    RuntimeConnection{paths.socket.c_str(), false}.bridge();
  case ServerAction::run:
  case ServerAction::help:
    return;
  }
}

}
}
