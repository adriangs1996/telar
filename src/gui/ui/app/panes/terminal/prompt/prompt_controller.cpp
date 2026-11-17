#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "prompt_controller.hpp"
#include "prompt_editor_item.hpp"
#include "ui/foundation/models/projection.hpp"
#include <QClipboard>
#include <QGuiApplication>
#include <algorithm>
#include <exception>

namespace telar::gui::qt {

  PromptController::PromptController(Store& store, QObject* parent)
      : QObject(parent),
        store_(store) {}

  prompt::Surface PromptController::surface(std::uint64_t pane_id) const noexcept {
    return store_.session().promptSurface(pane_id);
  }

  bool PromptController::edits(std::uint64_t pane_id) const noexcept {
    return store_.session().editsPrompt(pane_id);
  }

  bool PromptController::hidesTerminalCursor(std::uint64_t pane_id) const noexcept {
    return store_.session().hidesTerminalCursor(pane_id);
  }

  const prompt::Line* PromptController::line(std::uint64_t pane_id) const noexcept {
    return store_.session().promptLine(pane_id);
  }

  std::string_view PromptController::suggestion(std::uint64_t pane_id) const noexcept {
    const auto& session = store_.session();
    const auto* line = session.promptLine(pane_id);

    return line == nullptr ? std::string_view{} : line->suggestion(session.promptHistory());
  }

  application::CommandPresence PromptController::commandPresence(std::uint64_t pane_id, std::string_view word) {
    try {
      return store_.session().commandPresence(pane_id, word);
    } catch (const std::exception&) {
      return application::CommandPresence::unknown;
    }
  }

  std::optional<std::size_t> PromptController::selectedBlock(std::uint64_t pane_id) const noexcept {
    return store_.session().selectedBlock(pane_id);
  }

  const application::Pane<Memory>* PromptController::pane(std::uint64_t pane_id) const noexcept {
    return store_.session().findPane(pane_id);
  }

  const Configuration& PromptController::configuration() const noexcept {
    return store_.session().configuration();
  }

  const std::optional<application::terminal::copy_mode::CopyState>& PromptController::copy() const noexcept {
    return application::terminal::copy_mode::view(store_.session()).state();
  }

  bool PromptController::key(std::uint64_t pane_id, const prompt::KeyPress& key) {
    auto& session = store_.session();

    try {
      const auto outcome = session.promptKey(pane_id, key);
      if (outcome == prompt::Outcome::terminal) {
        return false;
      }

      if (outcome == prompt::Outcome::search_history) {
        emit historyRequested();
        return true;
      }
    } catch (const std::exception& error) {
      // A command the shell cannot receive (controls, size) stays in the editor.
      emit failed(QString::fromUtf8(error.what()));
    }

    if (session.takeClipboardWrite()) {
      QGuiApplication::clipboard()->setText(toQString(session.clipboard()));
    }

    publish(pane_id);
    if (session.takeBlockChange()) {
      emit blockChanged(pane_id);
    }

    if (application::terminal::copy_mode::takeSearchRequest(session)) {
      emit searchRequested();
    }

    return true;
  }

  bool PromptController::text(std::uint64_t pane_id, const QString& text) {
    auto& session = store_.session();
    if (!session.editsPrompt(pane_id)) {
      return false;
    }

    const auto bytes = text.toUtf8();

    session.promptText(pane_id, {bytes.constData(), static_cast<std::size_t>(bytes.size())});
    publishWrite();
    return true;
  }

  void PromptController::publish(qulonglong pane_id) {
    refresh(pane_id);
    emit lineChanged(pane_id);
  }

  void PromptController::publishWrite() {
    if (const auto pane_id = store_.session().takePromptWrite()) {
      publish(*pane_id);
    }
  }

  void PromptController::attach(PromptEditorItem& editor) {
    const auto free = std::ranges::find(editors_, nullptr);
    if (free == editors_.end()) {
      editors_.push_back(&editor);
    } else {
      *free = &editor;
    }
  }

  void PromptController::detach(PromptEditorItem& editor) {
    std::ranges::replace(editors_, &editor, nullptr);
  }

  void PromptController::refresh(qulonglong pane_id) {
    for (std::size_t index = 0; index < editors_.size(); ++index) {
      if (auto* editor = editors_[index]) {
        editor->refreshPane(pane_id);
      }
    }
  }

  void PromptController::configure() {
    for (std::size_t index = 0; index < editors_.size(); ++index) {
      if (auto* editor = editors_[index]) {
        editor->refresh();
      }
    }
  }

}
