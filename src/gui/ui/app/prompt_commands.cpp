#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"

namespace telar::gui::qt {

  void ApplicationController::initializePrompt() {
    connect(&terminals_, &TerminalController::terminalChanged, &prompt_, &PromptController::refresh);
    connect(this, &ApplicationController::configurationChanged, &prompt_, &PromptController::configure);
    connect(&prompt_, &PromptController::historyRequested, this, [this] {
      execute(window_actions::Action::history);
    });

    connect(&prompt_, &PromptController::blockChanged, this, [this](qulonglong pane_id) {
      emit terminals_.terminalChanged(pane_id);
      status_.publish();
    });

    connect(&prompt_, &PromptController::searchRequested, this, [this] {
      dialogs_.show(Dialog::copy_search);
    });

    connect(&prompt_, &PromptController::failed, &status_, &WindowStatus::report);
  }

}
