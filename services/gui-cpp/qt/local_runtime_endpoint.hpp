#pragma once

#include "core/memory.hpp"
#include "platform/runtime_endpoint.hpp"
#include "telar_platform/process_environment.hpp"
#include "telar_platform/runtime_paths.hpp"
#include "telar_platform/server_options.hpp"
#include <QLocalSocket>
#include <QString>
#include <QtCore/qtypes.h>

namespace telar::gui::qt {

struct NativeRuntimeStartup {
  [[nodiscard]] static QString resolve() {
    return QString::fromStdString(platform::runtime_endpoint::resolve());
  }
};

template <typename Startup = NativeRuntimeStartup>
struct LocalRuntimeEndpoint {
  template <Allocator Memory, runtime::EnvironmentLookup Environment = runtime::ProcessEnvironment>
  [[nodiscard]] static QString resolve(Memory &memory, const Environment &environment = {}) {
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
