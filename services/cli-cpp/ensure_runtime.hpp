#pragma once

#include "server.hpp"

namespace telar::runtime::cli {

// Starts the sibling runtime only for commands whose Zig Session.open did so.
// Runtime status/reporting uses Session.attach and must never resurrect it.
template <Allocator Memory>
void ensureRuntime(Memory &memory, const RuntimePaths<Memory> &paths) {
  std::optional<RuntimeConnection> connection;
  if (connectExisting(connection, paths.socket.c_str())) {
    return;
  }

  paths.prepareSocket();
  const auto child = launchDaemon(memory, ServerOptions{}, paths, ExecutablePath{runtime_program});
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};
  while (!connectExisting(connection, paths.socket.c_str())) {
    int status = 0;
    if (::waitpid(child, &status, WNOHANG) == child) {
      throw std::runtime_error{"RuntimeStartFailed"};
    }

    if (std::chrono::steady_clock::now() >= deadline) {
      throw std::runtime_error{"RuntimeTimeout"};
    }

    std::this_thread::sleep_for(std::chrono::milliseconds{10});
  }
}

}
