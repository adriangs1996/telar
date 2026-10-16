module;
#include "native-backends/application.hpp"
#include <coroutine>
#include <cstdint>
#include <cstdio>
#include <utility>
#include <variant>
export module app;

import app_context;
import app_state;

template <typename... Ts> struct overloaded : Ts... {
  using Ts::operator()...;
};

export template <Notifier INotifier> struct App final : ApplicationHost {
  bool exited = false;
  std::uint8_t exit_code = 0;

  explicit App(AppContext<INotifier> &context) : context(context) {}

  const AppState &state() const noexcept { return app_state; }

  bool requestExit() override { return context.input_queue.push(Exit{}); }

  bool update() override {
    for (auto input : context.input_queue.drain()) {
      process(input);
    }

    return !exited;
  }

private:
  AppContext<INotifier> &context;
  AppState app_state;

  void process(Event &input) {
    std::visit(overloaded{
                   [&](KeyPress &keypress) {

                   },
                   [&](Exit &exitrequest) {
                     exited = true;
                     exit_code = exitrequest.code;
                   },
                   [&](WorkspaceUpdated &event) {
                     app_state.workspaces_revision = event.revision;
                     app_state.workspaces = std::move(event.workspaces);

                     std::fprintf(stderr, "Runtime workspaces: %zu\n", app_state.workspaces.size());
                   },
               },
               input);
  }
};
