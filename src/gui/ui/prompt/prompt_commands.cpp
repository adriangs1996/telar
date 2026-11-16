#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/app/application_controller.hpp"
#include <QClipboard>
#include <QGuiApplication>
#include <exception>

namespace telar::gui::qt {

  prompt::Surface ApplicationController::promptSurface(std::uint64_t pane_id) const noexcept {
    return session().promptSurface(pane_id);
  }

  bool ApplicationController::editsPrompt(std::uint64_t pane_id) const noexcept {
    return session().editsPrompt(pane_id);
  }

  bool ApplicationController::hidesTerminalCursor(std::uint64_t pane_id) const noexcept {
    return session().hidesTerminalCursor(pane_id);
  }

  const prompt::Line* ApplicationController::promptLine(std::uint64_t pane_id) const noexcept {
    return session().promptLine(pane_id);
  }

  std::string_view ApplicationController::promptSuggestion(std::uint64_t pane_id) const noexcept {
    const auto* line = session().promptLine(pane_id);

    return line == nullptr ? std::string_view{} : line->suggestion(session().promptHistory());
  }

  CommandPresence ApplicationController::commandPresence(std::uint64_t pane_id, std::string_view word) {
    try {
      return session().commandPresence(pane_id, word);
    } catch (const std::exception&) {
      return CommandPresence::unknown;
    }
  }

  std::optional<std::size_t> ApplicationController::selectedBlock(std::uint64_t pane_id) const noexcept {
    return session().selectedBlock(pane_id);
  }

  void ApplicationController::selectBlock(std::uint64_t pane_id, std::optional<std::size_t> index) {
    try {
      session().selectBlock(pane_id, index);
    } catch (const std::exception& error) {
      fail(error);
    }

    emit promptChanged(pane_id);
    emit terminalChanged(pane_id);
  }

  void ApplicationController::scrollPaneToRow(std::uint64_t pane_id, std::uint32_t row) {
    try {
      session().scrollToRow(pane_id, row);
    } catch (const std::exception& error) {
      fail(error);
    }
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
