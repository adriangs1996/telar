#pragma once

#include "server.hpp"

namespace telar::runtime::cli {

// Zig's `Session.open`: connects to the runtime, starting it when none
// listens. Commands that only report (Zig's `Session.attach`) must never
// resurrect a stopped runtime and do not call this.
template <Allocator Memory>
void ensureRuntime(Memory &memory, const RuntimePaths<Memory> &paths, const ServerOptions &options = {}) {
  std::optional<RuntimeConnection> connection;
  if (connectExisting(connection, paths.socket.c_str())) {
    return;
  }

  if (startRuntime(memory, options, paths) != RuntimeStart::listening) {
    throw std::runtime_error{"RuntimeUnavailable"};
  }
}

}
