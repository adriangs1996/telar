module;
#include "native-backends/application.hpp"
#include "runtime_session.hpp" // IWYU pragma: export
#include "desktop_session.hpp" // IWYU pragma: export
#include "shortcuts.hpp"       // IWYU pragma: export
#include <cstdint>
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

  explicit App(AppContext<INotifier> &context)
      : context(context) {}

  const AppState &state() const noexcept {
    return app_state;
  }

  void start() override {
    context.shortcuts.setSink([this](Shortcuts::Request request) {
      return context.input_queue.push(std::move(request));
    });

    context.desktop.start(
        [this](DesktopState state) {
          return context.input_queue.push(DesktopUpdated{std::move(state)});
        },
        [this](DesktopCommand command) {
          return context.input_queue.push(DesktopRequested{std::move(command)});
        });
  }

  void stop() override {
    context.shortcuts.setSink({});
    context.desktop.stop();
  }

  bool requestExit() override {
    return context.input_queue.push(Exit{});
  }

  bool update() override {
    for (auto &input : context.input_queue.drain()) {
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
                   [&](RuntimeUpdated &event) {
                     app_state.workspaces_revision = event.state.workspaces_revision;
                     app_state.workspaces = event.state.workspaces;
                     context.runtime.apply(std::move(event.state));
                     context.desktop.reconcile(app_state.workspaces,
                                               context.runtime.state().connected &&
                                                   context.runtime.state().workspaces_ready);
                     synchronizeWorkspace();
                   },
                   [&](DesktopUpdated &event) {
                     if (context.desktop.state().focused_space != event.state.focused_space) {
                       context.shortcuts.cancel();
                     }

                     context.desktop.apply(std::move(event.state));
                     synchronizeWorkspace();
                   },
                   [&](DesktopRequested &event) {
                     context.desktop.execute(event.command);
                     synchronizeWorkspace();
                   },
                   [&](Shortcuts::Request &event) {
                     context.shortcuts.dispatch(event);
                   },
               },
               input);
  }

  void synchronizeWorkspace() {
    const auto workspace = context.desktop.focusedWorkspace();
    context.runtime.selectWorkspace(workspace ? std::optional{RuntimeWorkspace{*workspace}}
                                              : std::nullopt);
  }
};
