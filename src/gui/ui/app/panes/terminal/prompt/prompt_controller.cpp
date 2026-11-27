#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "prompt_controller.hpp"
#include "prompt_editor_item.hpp"
#include "telar_base/ds/values.hpp"
#include "ui/kit/models/projection.hpp"
#include <QClipboard>
#include <QGuiApplication>
#include <algorithm>
#include <exception>

namespace telar::gui::qt {

  PromptController::PromptController(Store& store, Memory& memory, QObject* parent)
      : QObject(parent),
        store_(store),
        editors_(memory) {}

  application::prompt::Surface PromptController::surface(std::uint64_t pane_id) const noexcept {
    return application::prompt::surface(store_.session(), pane_id);
  }

  bool PromptController::edits(std::uint64_t pane_id) const noexcept {
    return application::prompt::edits(store_.session(), pane_id);
  }

  bool PromptController::hidesTerminalCursor(std::uint64_t pane_id) const noexcept {
    return application::prompt::hidesTerminalCursor(store_.session(), pane_id);
  }

  ds::Option<application::prompt::LineView> PromptController::line(std::uint64_t pane_id) const noexcept {
    return application::prompt::line(store_.session(), pane_id);
  }

  std::string_view PromptController::suggestion(std::uint64_t pane_id) const noexcept {
    return application::prompt::suggestion(store_.session(), pane_id);
  }

  application::prompt::CommandPresence PromptController::commandPresence(std::uint64_t pane_id, std::string_view word) {
    try {
      return application::prompt::commandPresence(store_.sessionMut(), pane_id, word);
    } catch (const std::exception&) {
      return application::prompt::CommandPresence::unknown;
    }
  }

  ds::Option<std::size_t> PromptController::selectedBlock(std::uint64_t pane_id) const noexcept {
    return store_.session().selectedBlock(pane_id);
  }

  void PromptController::textCommand(std::uint64_t pane_id, application::prompt::TextCommand command) {
    application::prompt::textCommand(store_.sessionMut(), pane_id, command);
    publish(pane_id);
  }

  void PromptController::placeCursor(std::uint64_t pane_id, std::size_t offset) {
    application::prompt::placeCursor(store_.sessionMut(), pane_id, offset);
    publish(pane_id);
  }

  bool PromptController::copyText(std::uint64_t pane_id, bool cut) {
    const auto selected = application::prompt::selectedText(store_.session(), pane_id);
    if (selected.empty()) {
      return false;
    }

    QGuiApplication::clipboard()->setText(toQString(selected));
    if (cut) {
      textCommand(pane_id, application::prompt::TextCommand::erase_selection);
    }

    return true;
  }

  bool PromptController::typingLeavesBlock(std::uint64_t pane_id) const noexcept {
    return store_.session().typingLeavesBlock(pane_id);
  }

  const application::Pane<Memory>* PromptController::pane(std::uint64_t pane_id) const noexcept {
    return store_.session().findPane(pane_id);
  }

  const Configuration& PromptController::configuration() const noexcept {
    return store_.session().configuration;
  }

  const ds::Option<application::terminal::copy_mode::CopyState>& PromptController::copy() const noexcept {
    return application::terminal::copy_mode::view(store_.session()).state();
  }

  bool PromptController::key(std::uint64_t pane_id, const application::prompt::KeyPress& key) {
    using application::prompt::Outcome;
    auto& session = store_.sessionMut();

    try {
      const auto outcome = application::prompt::key(session, pane_id, key);
      if (outcome == Outcome::terminal) {
        return false;
      }

      if (outcome == Outcome::search_history) {
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
    auto& session = store_.sessionMut();
    if (!application::prompt::edits(session, pane_id)) {
      return false;
    }

    const auto bytes = text.toUtf8();
    const std::string_view typed{bytes.constData(), static_cast<std::size_t>(bytes.size())};
    if (application::prompt::toProgram(session, pane_id, typed)) {
      return false;
    }

    application::prompt::text(session, pane_id, typed);
    publishWrite();
    return true;
  }

  void PromptController::publish(qulonglong pane_id) {
    refresh(pane_id);
    emit lineChanged(pane_id);
  }

  void PromptController::publishWrite() {
    if (const auto pane_id = application::prompt::takeWrite(store_.sessionMut())) {
      publish(*pane_id);
    }
  }

  void PromptController::attach(PromptEditorItem& editor) {
    // Held by address, as Qt holds its items: each editor detaches before it is destroyed.
    auto* const held = tbc::raw(&editor);
    const auto attached = editors_.viewMut();
    const auto free = std::ranges::find(attached, nullptr);
    if (free == attached.end()) {
      editors_.push(held);
    } else {
      *free = held;
    }
  }

  void PromptController::detach(PromptEditorItem& editor) {
    std::ranges::replace(editors_.viewMut(), &editor, nullptr);
  }

  void PromptController::refresh(qulonglong pane_id) {
    for (auto* editor : editors_) {
      if (editor != nullptr) {
        editor->refreshPane(pane_id);
      }
    }
  }

  void PromptController::configure() {
    for (auto* editor : editors_) {
      if (editor != nullptr) {
        editor->refresh();
      }
    }
  }

}
