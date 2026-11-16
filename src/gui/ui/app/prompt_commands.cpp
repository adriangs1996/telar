#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"

namespace telar::gui::qt {

  void ApplicationController::initializePrompt() {
    connect(this, &ApplicationController::terminalChanged, &prompt_, &PromptController::refresh);
    connect(this, &ApplicationController::configurationChanged, &prompt_, &PromptController::configure);
    connect(&prompt_, &PromptController::historyRequested, this, [this] {
      execute(Action::history);
    });
    connect(&prompt_, &PromptController::blockChanged, this, [this](qulonglong pane_id) {
      emit terminalChanged(pane_id);
      publishStatus();
    });
    connect(&prompt_, &PromptController::searchRequested, this, [this] {
      showDialog(Dialog::copy_search);
    });
    connect(&prompt_, &PromptController::failed, this, &ApplicationController::reportFailure);
  }

}
