module telar.gui.ui.app.panes.terminal;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.input;
import telar.base.ds;
import telar.gui.foundation.actions;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  CopyController::CopyController(Store& store, QObject* parent)
      : QObject(parent),
        store_(store) {
    clock_.start();
  }

  bool CopyController::idle() const noexcept {
    return store_.dialog().kind == Store::Dialog::none;
  }

  bool CopyController::active() const noexcept {
    return application::terminal::copy_mode::view(store_.session()).active();
  }

  const ds::Option<application::terminal::copy_mode::CopyState>& CopyController::state() const noexcept {
    return application::terminal::copy_mode::view(store_.session()).state();
  }

  void CopyController::publish() {
    if (const auto now = active(); now != published_active_) {
      published_active_ = now;
      activeChanged();
    }
  }

  void CopyController::publishSearch() {
    searchChanged();
  }

  void CopyController::publishChange(std::uint64_t previous_pane) {
    const auto& copy = state();

    if (previous_pane != 0) {
      paneChanged(previous_pane);
    }

    if (copy && copy->pane_id != previous_pane) {
      paneChanged(copy->pane_id);
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
      const auto effect = application::terminal::copy_mode::key(store_.sessionMut(), *semantic);
      if (effect.search) {
        searchRequested();
      }

      if (effect.open_link && state()) {
        linkRequested(pane_id, state()->cursor);
      }

      paneChanged(pane_id);
      publish();
    } catch (const std::exception& error) {
      failed(QString::fromUtf8(error.what()));
    }

    return true;
  }

  void CopyController::leaveKeyboard() {
    const auto& copy = state();
    if (copy && !copy->pointer) {
      const auto pane_id = copy->pane_id;

      application::terminal::copy_mode::leave(store_.sessionMut());
      publishChange(pane_id);
    }
  }

  bool CopyController::beginSelection(std::uint64_t pane_id, CopyPoint local) {
    if (!idle()) {
      return false;
    }

    inputStarted();
    const auto& copy = state();
    const auto previous = copy ? copy->pane_id : 0;
    const auto began = application::terminal::copy_mode::press(store_.sessionMut(), {.pane_id = pane_id, .position = local, .now_ns = static_cast<std::uint64_t>(clock_.nsecsElapsed())});
    if (began) {
      publishChange(previous);
    }

    return began;
  }

  bool CopyController::handlePointer(const application::terminal::copy_mode::CopyPointerInput& input) {
    auto& session = store_.sessionMut();
    const auto owner = application::terminal::copy_mode::view(session).pointerOwner();
    if (!idle() && (!owner || !owner->dragging)) {
      return true;
    }

    if (input.kind == application::terminal::copy_mode::CopyPointerKind::press || input.kind == application::terminal::copy_mode::CopyPointerKind::wheel) {
      inputStarted();
    }

    const auto& copy = state();
    const auto previous = copy ? copy->pane_id : 0;
    const auto revision = application::terminal::copy_mode::view(session).revision();

    try {
      const auto outcome = application::terminal::copy_mode::pointer(session, input);

      if (application::terminal::copy_mode::view(session).revision() != revision) {
        publishChange(previous);
      }

      return outcome != application::terminal::copy_mode::CopyPointerDecision::Outcome::unowned;
    } catch (const std::exception& error) {
      failed(QString::fromUtf8(error.what()));

      return true;
    }
  }

  void CopyController::copySelection(std::uint64_t pane_id) {
    try {
      static_cast<void>(application::terminal::copy_mode::copy(store_.sessionMut(), pane_id));
    } catch (const std::exception& error) {
      failed(QString::fromUtf8(error.what()));
    }
  }

  void CopyController::toggleSearchScope() {
    auto& session = store_.sessionMut();

    application::terminal::copy_mode::toggleSearchScope(session);
    searchChanged();
    // The query typed so far, looked for again where it now looks.
    const auto query = application::terminal::copy_mode::searchState(session).query;

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

      application::terminal::copy_mode::search(store_.sessionMut(), {bytes.constData(), static_cast<std::size_t>(bytes.size())});
    } catch (const std::exception& error) {
      failed(QString::fromUtf8(error.what()));
    }

    paneChanged(pane_id);
    searchChanged();
  }

  void CopyController::step(bool forward) {
    const auto& copy = state();
    if (!copy) {
      return;
    }

    const auto pane_id = copy->pane_id;

    try {
      application::terminal::copy_mode::stepMatch(store_.sessionMut(), forward);
    } catch (const std::exception& error) {
      failed(QString::fromUtf8(error.what()));
    }

    paneChanged(pane_id);
    searchChanged();
  }

  void CopyController::finishSearch() {
    application::terminal::copy_mode::finishSearch(store_.sessionMut());
    closeRequested();
    searchChanged();
  }

  QVariantMap CopyController::searchState() const {
    const auto search = application::terminal::copy_mode::searchState(store_.session());

    return {
        {u"query"_s, QString::fromUtf8(search.query.data(), static_cast<qsizetype>(search.query.size()))},
        {u"searching"_s, search.searching},
        {u"count"_s, static_cast<int>(search.count)},
        {u"index"_s, static_cast<int>(search.index)},
        {u"truncated"_s, search.truncated},
        {u"scope"_s, searchScope()},
        {u"scopes"_s, searchScopes()},
    };
  }

  QString CopyController::searchScope() const {
    const auto& session = store_.session();
    const auto block = application::terminal::copy_mode::searchBlock(session);
    const auto& copy = state();
    const auto* pane = block && copy ? session.findPane(copy->pane_id) : nullptr;
    if (pane == nullptr || *block >= pane->blocks.size()) {
      return {};
    }

    const auto command = pane->blocks[*block].command;

    return QString::fromUtf8(command.data(), static_cast<qsizetype>(command.size()));
  }

  bool CopyController::searchScopes() const {
    return application::terminal::copy_mode::searchScopes(store_.session());
  }

}
