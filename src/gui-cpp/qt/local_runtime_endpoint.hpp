#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../core/memory.hpp"
#include <string>
#include <concepts>
#include <cstdlib>
#include <string_view>
#include "telar_base/memory/allocator.hpp"
#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include <algorithm>
#include <array>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <span>
#include <stdexcept>
#include <charconv>
#include <sys/un.h>
#include <QLocalSocket>
#include <QString>
#include <QtCore/qtypes.h>

#pragma once

#include "core/memory.hpp"


import telar.gui.platform.profile_file;
import telar.platform;

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
