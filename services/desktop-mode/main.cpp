#include <coroutine>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>

#include "native-backends/application.hpp"
#include "telar_client/telar.hpp"

import app;
import app_context;
import runtime_receiver_worker;

int main(int argc, const char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "Usage: %s SOCKET_PATH\n", argv[0]);
    return 1;
  }

  lua::Vm lua_vm;
  ApplicationWakeup wakeup;
  EventQueue input_queue{wakeup};

  auto client = telar::Client::init(argv[1]);
  AppContext context{.client = client, .input_queue = input_queue, .lua_vm = lua_vm};
  App app(context);

  try {
    client.handshake();
    auto runtime_reader = RuntimeReceiverWorker::init(context);

    std::random_device entropy;
    std::uniform_int_distribution<std::uint64_t> identities(1);
    const auto client_identity = identities(entropy);

    client.send(telar::RequestRuntimeState{
        .client_identity = client_identity,
        .interactive = true,
    });

    const int application_result = runApplication(app, wakeup, app.state());
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
