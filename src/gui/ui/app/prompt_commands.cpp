#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include <QClipboard>
#include <QGuiApplication>
#include <exception>

namespace telar::gui::qt {

  void ApplicationController::initializePrompt() {
    connect(this, &ApplicationController::promptChanged, &prompt_, &PromptController::refresh);
    connect(this, &ApplicationController::terminalChanged, &prompt_, &PromptController::refresh);
    connect(this, &ApplicationController::configurationChanged, &prompt_, &PromptController::configure);
  }

  bool ApplicationController::promptKey(std::uint64_t pane_id, const prompt::KeyPress& key) {
    try {
      const auto outcome = session().promptKey(pane_id, key);
      if (outcome == prompt::Outcome::terminal) {
        return false;
      }

      if (outcome == prompt::Outcome::search_history) {
        execute(Action::history);
        return true;
      }
    } catch (const std::exception& error) {
      // A command the shell cannot receive (controls, size) stays in the editor.
      fail(error);
    }

    if (session().takeClipboardWrite()) {
      QGuiApplication::clipboard()->setText(toQString(session().clipboard()));
    }

    emit promptChanged(pane_id);
    // A block selected or left scrolls the pane, and copy mode may begin on it.
    if (session().takeBlockChange()) {
      emit terminalChanged(pane_id);
      publishStatus();
    }

    // A search of a command's output asks for its query.
    if (session().takeSearchRequest()) {
      showDialog(Dialog::copy_search);
    }

    return true;
  }

  bool ApplicationController::promptText(std::uint64_t pane_id, const QString& text) {
    if (!session().editsPrompt(pane_id)) {
      return false;
    }

    const auto bytes = text.toUtf8();

    session().promptText(pane_id, {bytes.constData(), static_cast<std::size_t>(bytes.size())});
    publishPromptWrite();
    return true;
  }

}
