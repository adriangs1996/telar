#pragma once

#include "runtime_connection.hpp"
#include "telar_platform/daemon.hpp"
#include <thread>

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

template <Allocator Memory>
void printEndpoint(Memory &memory, const ServerOptions &options, const RuntimePaths<Memory> &paths) {
  std::optional<RuntimeConnection> connection;
  if (!connectExisting(connection, paths.socket.c_str())) {
    paths.prepareSocket();
    const auto child = launchDaemon(memory, options, paths, ExecutablePath{runtime_program});
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};
    while (!connectExisting(connection, paths.socket.c_str())) {
      int status = 0;
      if (::waitpid(child, &status, WNOHANG) == child) {
        throw SystemError{"Runtime failed to start; inspect its .runtime.start.log", ECHILD};
      }
      if (std::chrono::steady_clock::now() >= deadline) {
        throw SystemError{"Runtime did not start within ten seconds", ETIMEDOUT};
      }

      std::this_thread::sleep_for(std::chrono::milliseconds{10});
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
