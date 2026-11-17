#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/memory.hpp"
#include <QLocalSocket>
#include <QString>
#include <QtCore/qtypes.h>
#include <cerrno>
#include <cstdlib>
#include <fcntl.h>
#include <limits.h>

#pragma once

import telar.gui.foundation.system;
import telar.platform.paths;

namespace telar::gui::qt {

  struct NativeRuntimeStartup {
    [[nodiscard]] static QString resolve() {
      return QString::fromStdString(system::runtime_endpoint::resolve());
    }
  };

  template <typename Startup = NativeRuntimeStartup>
  struct LocalRuntimeEndpoint {
    template <Allocator Memory, runtime::EnvironmentLookup Environment = runtime::ProcessEnvironment>
    [[nodiscard]] static QString resolve(Memory& memory, const Environment& environment = {}) {
      const runtime::cli::ServerOptions options{};
      const runtime::cli::RuntimePaths paths(memory, options, environment);
      auto path = QString::fromUtf8(paths.socket.data(), static_cast<qsizetype>(paths.socket.size()));
      QLocalSocket probe;

      probe.connectToServer(path);
      constexpr int connect_deadline_ms = 100;
      if (probe.state() == QLocalSocket::ConnectedState || probe.waitForConnected(connect_deadline_ms)) {
        probe.abort();

        return path;
      }

      return Startup::resolve();
    }
  };

}
