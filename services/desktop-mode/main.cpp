#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <optional>
#include <string>
#include <unistd.h>

#include "log_categories.hpp"
#include "native-backends/application.hpp"
#include "session_log.hpp"
#include "telar_client/telar.hpp"
#include "runtime_endpoint.hpp"
#include "runtime_session.hpp"
#include "desktop_session.hpp"
#include "shortcuts.hpp"
#include "ui/services.hpp"

import app;
import app_context;
import runtime_receiver_worker;

static int runDesktop(int argc, const char **argv, ApplicationWakeup &wakeup) {
  if (argc > 2) {
    std::fprintf(stderr, "Usage: %s [SOCKET_PATH]\n", argv[0]);
    return 1;
  }

  // An explicit socket names a runtime someone else started, such as a development one with its
  // own history, so it is never started from here.
  const std::string socket = argc == 2 ? argv[1] : runtime_endpoint::resolve();
  qCInfo(telar_log::session) << "Desktop session starting; pid" << ::getpid() << "runtime socket"
                             << socket.c_str();
  lua::Vm lua_vm;
  EventQueue input_queue{wakeup};

  auto client = telar::Client::init(socket.c_str());
  RuntimeSession runtime{client, socket};
  DesktopSession desktop{socket};
  Shortcuts shortcuts;
  AppContext context{.client = client,
                     .input_queue = input_queue,
                     .lua_vm = lua_vm,
                     .runtime = runtime,
                     .desktop = desktop,
                     .shortcuts = shortcuts};
  App app(context);

  try {
    client.handshake();
    qCInfo(telar_log::session) << "Runtime handshake completed";
    std::random_device entropy;
    std::uniform_int_distribution<std::uint64_t> identities(1);
    const auto client_identity = identities(entropy);

    client.send(telar::RequestRuntimeState{
        .client_identity = client_identity,
        .interactive = false,
    });

    auto runtime_reader = RuntimeReceiverWorker::init(context);
    ui::Services services{lua_vm, runtime, desktop, shortcuts, socket};
    const int application_result = runApplication(app, wakeup, app.state(), services);
    qCInfo(telar_log::session) << "Application loop finished with" << application_result;
    runtime_reader.stop();

    if (application_result != EXIT_SUCCESS) {
      app.exit_code = EXIT_FAILURE;
    }

  } catch (...) {
    client.deinit();
    throw;
  }

  client.deinit();

  return app.exit_code;
}

int main(int argc, const char **argv) {
  // Signal handling must precede even the trace writer thread, and outlive it.
  std::optional<ApplicationWakeup> wakeup;
  int result = EXIT_FAILURE;

  try {
    wakeup.emplace();
    session_log::open();
    result = runDesktop(argc, argv, *wakeup);
  } catch (const std::exception &error) {
    // Critical messages also reach the console, in release builds too.
    qCCritical(telar_log::session) << "Telar Desktop:" << error.what();
  }

  qCInfo(telar_log::session) << "Desktop session exiting with" << result;
  session_log::close();
  return result;
}
