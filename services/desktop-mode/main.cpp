#include <cstdio>
#include <unistd.h>
#include <variant>

#include "telar_client/telar.hpp"

import app_context;
import runtime_receiver_worker;

#define MAX_SPACES 10
#define MAX_TABS 1000
#define MAX_PANES 10000

struct Space {
  std::uint16_t id;
  std::uint16_t index;
  std::uint16_t tabs_count = 0;
};

struct Tab {
  std::uint16_t id;
  std::uint16_t space_id;
  std::uint16_t panes_count = 0;
};

struct Pane {
  std::uint16_t id;
  std::uint16_t tab_id;
};

template <typename... Ts> struct overloaded : Ts... {
  using Ts::operator()...;
};

struct App {
  Space spaces[MAX_SPACES] = {};
  Tab tabs[MAX_TABS] = {};
  Pane panes[MAX_PANES] = {};
  bool exited = false;
  std::uint8_t exit_code;

  void loop(AppContext &context) {
    while (!exited) {
      for (auto input : context.input_queue.drain()) {
        process(input);
      }
    }
  }

private:
  void process(Event input) {
    std::visit(overloaded{
                   [&](KeyPress &keypress) {

                   },
                   [&](Exit &exitrequest) {
                     exited = true;
                     exit_code = exitrequest.code;
                   },
               },
               input);
  }
};

static App state{};

int main(int argc, const char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "Usage: %s SOCKET_PATH\n", argv[0]);
    return 1;
  }

  EventQueue input_queue{};
  auto client = telar::Client::init(argv[1]);
  const AppContext context{.client = client, .input_queue = input_queue};

  try {
    client.handshake();
    auto runtime_reader = RuntimeReceiverWorker::init(context);
    runtime_reader.wait();
  } catch (...) {
    client.deinit();
    throw;
  }

  client.deinit();

  return state.exit_code;
}
