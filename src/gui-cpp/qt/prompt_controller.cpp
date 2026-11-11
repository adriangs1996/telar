#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application.hpp"
#include <exception>
#include <QClipboard>
#include <QGuiApplication>

namespace telar::gui::qt {

prompt::Surface Application::promptSurface(std::uint64_t pane_id) const noexcept {
  return session().promptSurface(pane_id);
}

bool Application::editsPrompt(std::uint64_t pane_id) const noexcept {
  return session().editsPrompt(pane_id);
}

const prompt::Island *Application::promptIsland(std::uint64_t pane_id) const noexcept {
  return session().island(pane_id);
}

std::string_view Application::promptSuggestion(std::uint64_t pane_id) const noexcept {
  const auto *island = session().island(pane_id);
  return island == nullptr ? std::string_view{} : island->suggestion(session().promptHistory());
}

CommandPresence Application::commandPresence(std::uint64_t pane_id, std::string_view word) {
  try {
    return session().commandPresence(pane_id, word);
  } catch (const std::exception &) {
    return CommandPresence::unknown;
  }
}

std::optional<std::size_t> Application::selectedBlock(std::uint64_t pane_id) const noexcept {
  return session().selectedBlock(pane_id);
}

void Application::selectBlock(std::uint64_t pane_id, std::optional<std::size_t> index) {
  try {
    session().selectBlock(pane_id, index);
  } catch (const std::exception &error) {
    fail(error);
  }
  emit promptChanged(pane_id);
  emit terminalChanged(pane_id);
}

void Application::scrollPaneToRow(std::uint64_t pane_id, std::uint32_t row) {
  try {
    session().scrollToRow(pane_id, row);
  } catch (const std::exception &error) {
    fail(error);
  }
}

bool Application::promptKey(std::uint64_t pane_id, const prompt::KeyPress &key) {
  try {
    const auto outcome = session().promptKey(pane_id, key);
    if (outcome == prompt::Outcome::terminal) {
      return false;
    }
    if (outcome == prompt::Outcome::search_history) {
      execute(Action::history);
      return true;
    }
  } catch (const std::exception &error) {
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
    emit stateChanged();
  }
  // A search of a command's output asks for its query.
  if (session().takeSearchRequest()) {
    showDialog(QStringLiteral("copy-search"));
  }
  return true;
}

void Application::toggleCopySearchScope() {
  session().toggleCopySearchScope();
  emit dialogChanged();
  // The query typed so far, looked for again where it now looks.
  const auto query = session().copySearch().query;
  searchScrollback(QString::fromUtf8(query.data(), static_cast<qsizetype>(query.size())));
}

void Application::searchScrollback(const QString &text) {
  const auto &copy = copyState();
  if (!copy) {
    return;
  }
  try {
    const auto bytes = text.toUtf8();
    session().searchCopy({bytes.constData(), static_cast<std::size_t>(bytes.size())});
  } catch (const std::exception &error) {
    fail(error);
  }
  emit terminalChanged(copy->pane_id);
  emit copySearchChanged();
}

void Application::stepScrollbackMatch(bool forward) {
  const auto &copy = copyState();
  if (!copy) {
    return;
  }
  try {
    session().stepCopyMatch(forward);
  } catch (const std::exception &error) {
    fail(error);
  }
  emit terminalChanged(copy->pane_id);
  emit copySearchChanged();
}

// The search typed so far stays, its matches for n and N; the line goes back to the editor.
void Application::finishScrollbackSearch() {
  session().finishCopySearch();
  showDialog({});
  emit copySearchChanged();
}

QVariantMap Application::copySearchState() const {
  const auto state = session().copySearch();
  return {
      {QStringLiteral("query"), QString::fromUtf8(state.query.data(), static_cast<qsizetype>(state.query.size()))},
      {QStringLiteral("searching"), state.searching},
      {QStringLiteral("count"), static_cast<int>(state.count)},
      {QStringLiteral("index"), static_cast<int>(state.index)},
      {QStringLiteral("truncated"), state.truncated},
      {QStringLiteral("scope"), copySearchScope()},
      {QStringLiteral("scopes"), copySearchScopes()},
  };
}

QString Application::copySearchScope() const {
  const auto block = session().copySearchBlock();
  const auto &copy = copyState();
  const auto *pane = block && copy ? session().findPane(copy->pane_id) : nullptr;
  if (pane == nullptr || *block >= pane->blocks.size()) {
    return {};
  }
  const auto command = pane->blocks[*block].command;
  return QString::fromUtf8(command.data(), static_cast<qsizetype>(command.size()));
}

bool Application::copySearchScopes() const {
  return session().copySearchScopes();
}

bool Application::promptText(std::uint64_t pane_id, const QString &text) {
  if (!session().editsPrompt(pane_id)) {
    return false;
  }

  const auto bytes = text.toUtf8();
  session().promptText(pane_id, {bytes.constData(), static_cast<std::size_t>(bytes.size())});
  publishPromptWrite();
  return true;
}

}
