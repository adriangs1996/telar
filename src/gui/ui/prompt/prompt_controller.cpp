#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "prompt_controller.hpp"
#include "prompt_editor_item.hpp"
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

  CommandPresence PromptController::commandPresence(std::uint64_t pane_id, std::string_view word) {
    try {
      return store_.session().commandPresence(pane_id, word);
    } catch (const std::exception&) {
      return CommandPresence::unknown;
    }
  }

  std::optional<std::size_t> PromptController::selectedBlock(std::uint64_t pane_id) const noexcept {
    return store_.session().selectedBlock(pane_id);
  }

  const Pane<Memory>* PromptController::pane(std::uint64_t pane_id) const noexcept {
    return store_.session().findPane(pane_id);
  }

  const Configuration& PromptController::configuration() const noexcept {
    return store_.session().configuration();
  }

  const std::optional<CopyState>& PromptController::copy() const noexcept {
    return store_.session().copyMode().state();
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
