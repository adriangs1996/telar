#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>

#include "native-backends/application.hpp"
#include "telar_client/telar.hpp"
#include "runtime_session.hpp"
#include "desktop_session.hpp"
#include "shortcuts.hpp"
#include "ui/services.hpp"

import app;
import app_context;
import runtime_receiver_worker;

static int runDesktop(int argc, const char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "Usage: %s SOCKET_PATH\n", argv[0]);
    return 1;
  }

  lua::Vm lua_vm;
  ApplicationWakeup wakeup;
  EventQueue input_queue{wakeup};

  auto client = telar::Client::init(argv[1]);
  RuntimeSession runtime{client};
  DesktopSession desktop{argv[1]};
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
    std::random_device entropy;
    std::uniform_int_distribution<std::uint64_t> identities(1);
    const auto client_identity = identities(entropy);

    client.send(telar::RequestRuntimeState{
        .client_identity = client_identity,
        .interactive = false,
    });

    auto runtime_reader = RuntimeReceiverWorker::init(context);
    ui::Services services{lua_vm, runtime, desktop, shortcuts};
    const int application_result = runApplication(app, wakeup, app.state(), services);
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
  try {
    return runDesktop(argc, argv);
  } catch (const std::exception &error) {
    std::fprintf(stderr, "Telar Desktop: %s\n", error.what());
    return EXIT_FAILURE;
  }
}
