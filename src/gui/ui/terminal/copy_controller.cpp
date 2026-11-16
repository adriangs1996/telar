#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "copy_controller.hpp"
#include "ui/input/key_adapter.hpp"
#include <QByteArray>
#include <exception>

import telar.gui.input.key_encoder;

namespace telar::gui::qt {

  CopyController::CopyController(Store& store, QObject* parent)
      : QObject(parent),
        store_(store) {
    clock_.start();
  }

  bool CopyController::idle() const noexcept {
    return store_.dialog().kind == Store::Dialog::none;
  }

  bool CopyController::active() const noexcept {
    return store_.session().copyMode().active();
  }

  const std::optional<CopyState>& CopyController::state() const noexcept {
    return store_.session().copyMode().state();
  }

  void CopyController::publish() {
    if (const auto now = active(); now != published_active_) {
      published_active_ = now;
      emit activeChanged();
    }
  }

  void CopyController::publishSearch() {
    emit searchChanged();
  }

  void CopyController::publishChange(std::uint64_t previous_pane) {
    const auto& copy = state();

    if (previous_pane != 0) {
      emit paneChanged(previous_pane);
    }

    if (copy && copy->pane_id != previous_pane) {
      emit paneChanged(copy->pane_id);
    }

    publish();
  }

  bool CopyController::handleKey(std::uint64_t pane_id, const QKeyEvent& event) {
    const auto& copy = state();
    if (!copy || copy->pointer || !idle() || copy->pane_id != pane_id) {
      return false;
    }

    const auto semantic = NativeKeyAdapter::terminalKey(event);
    if (!semantic || semantic->has(KeyChord::Modifier::super)) {
      return true;
    }

    try {
      const auto effect = store_.session().copyKey(*semantic);
      if (effect.search) {
        emit searchRequested();
      }

      if (effect.open_link && state()) {
        emit linkRequested(pane_id, state()->cursor);
      }

      emit paneChanged(pane_id);
      publish();
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }

    return true;
  }

  void CopyController::leaveKeyboard() {
    const auto& copy = state();
    if (copy && !copy->pointer) {
      const auto pane_id = copy->pane_id;

      store_.session().leaveCopyMode();
      publishChange(pane_id);
    }
  }

  bool CopyController::beginSelection(std::uint64_t pane_id, CopyPoint local) {
    if (!idle()) {
      return false;
    }

    emit inputStarted();
    const auto& copy = state();
    const auto previous = copy ? copy->pane_id : 0;
    const auto began = store_.session().beginSelection({.pane_id = pane_id, .position = local, .now_ns = static_cast<std::uint64_t>(clock_.nsecsElapsed())});
    if (began) {
      publishChange(previous);
    }

    return began;
  }

  bool CopyController::handlePointer(const CopyPointerInput& input) {
    auto& session = store_.session();
    const auto owner = session.copyMode().pointerOwner();
    if (!idle() && (!owner || !owner->dragging)) {
      return true;
    }

    if (input.kind == CopyPointerKind::press || input.kind == CopyPointerKind::wheel) {
      emit inputStarted();
    }

    const auto& copy = state();
    const auto previous = copy ? copy->pane_id : 0;
    const auto revision = session.copyMode().revision();

    try {
      const auto outcome = session.pointer(input);

      if (session.copyMode().revision() != revision) {
        publishChange(previous);
      }

      return outcome != CopyPointerDecision::Outcome::unowned;
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));

      return true;
    }
  }

  void CopyController::copySelection(std::uint64_t pane_id) {
    try {
      static_cast<void>(store_.session().copySelection(pane_id));
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }
  }

  void CopyController::toggleSearchScope() {
    auto& session = store_.session();

    session.toggleCopySearchScope();
    emit searchChanged();
    // The query typed so far, looked for again where it now looks.
    const auto query = session.copySearch().query;

    search(QString::fromUtf8(query.data(), static_cast<qsizetype>(query.size())));
  }

  void CopyController::search(const QString& text) {
    const auto& copy = state();
    if (!copy) {
      return;
    }

    const auto pane_id = copy->pane_id;

    try {
      const auto bytes = text.toUtf8();

      store_.session().searchCopy({bytes.constData(), static_cast<std::size_t>(bytes.size())});
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }

    emit paneChanged(pane_id);
    emit searchChanged();
  }

  void CopyController::step(bool forward) {
    const auto& copy = state();
    if (!copy) {
      return;
    }

    const auto pane_id = copy->pane_id;

    try {
      store_.session().stepCopyMatch(forward);
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }

    emit paneChanged(pane_id);
    emit searchChanged();
  }

  void CopyController::finishSearch() {
    store_.session().finishCopySearch();
    emit closeRequested();
    emit searchChanged();
  }

  QVariantMap CopyController::searchState() const {
    const auto search = store_.session().copySearch();

    return {
        {QStringLiteral("query"), QString::fromUtf8(search.query.data(), static_cast<qsizetype>(search.query.size()))},
        {QStringLiteral("searching"), search.searching},
        {QStringLiteral("count"), static_cast<int>(search.count)},
        {QStringLiteral("index"), static_cast<int>(search.index)},
        {QStringLiteral("truncated"), search.truncated},
        {QStringLiteral("scope"), searchScope()},
        {QStringLiteral("scopes"), searchScopes()},
    };
  }

  QString CopyController::searchScope() const {
    const auto& session = store_.session();
    const auto block = session.copySearchBlock();
    const auto& copy = state();
    const auto* pane = block && copy ? session.findPane(copy->pane_id) : nullptr;
    if (pane == nullptr || *block >= pane->blocks.size()) {
      return {};
    }

    const auto command = pane->blocks[*block].command;

    return QString::fromUtf8(command.data(), static_cast<qsizetype>(command.size()));
  }

  bool CopyController::searchScopes() const {
    return store_.session().copySearchScopes();
  }

}
