export module telar.gui.ui.app:local_runtime_endpoint;

import std;
import telar.gui.qt;
import telar.gui.foundation.system;
import telar.platform.paths;
import telar.gui.foundation.core;

export namespace telar::gui::qt {

  struct NativeRuntimeStartup {
    [[tbc::hot_path]] [[nodiscard]] inline static QString resolve() {
      const auto endpoint = system::runtime_endpoint::resolve();

      return QString::fromUtf8(endpoint.view().data(), static_cast<qsizetype>(endpoint.view().size()));
    }
  };

  template <typename Startup = NativeRuntimeStartup>
  struct LocalRuntimeEndpoint {
    template <Allocator Memory, runtime::EnvironmentLookup Environment = runtime::ProcessEnvironment>
    [[tbc::generic]] [[nodiscard]] static QString resolve(Memory& memory, const Environment& environment = {}) {
      const runtime::cli::ServerOptions options{};
      const runtime::cli::RuntimePaths<Memory> paths(memory, options, environment);
      auto path = QString::fromUtf8(paths.socket.data(), static_cast<qsizetype>(paths.socket.size()));
      QLocalSocket probe;

      probe.connectToServer(path);
      constexpr int connect_deadline_ms = 100;
      if (probe.state() == QLocalSocket::ConnectedState || probe.waitForConnected(connect_deadline_ms)) {
        probe.abort();
      } else {
        path = Startup::resolve();
      }

      return path;
    }
  };

}
