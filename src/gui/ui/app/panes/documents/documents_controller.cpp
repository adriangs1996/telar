module telar.gui.ui.app.panes.documents;

import telar.gui.qt;

namespace telar::gui::qt {

  DocumentsController::DocumentsController(Store& store, QObject* parent)
      : QObject(parent),
        store_(store) {}

  const application::Pane<Memory>* DocumentsController::pane(std::uint64_t pane_id) const noexcept {
    return store_.session().findPane(pane_id);
  }

  bool DocumentsController::key(std::uint64_t pane_id, const QKeyEvent& event) {
    const auto* current = pane(pane_id);
    if (current == nullptr || !current->document_shown) {
      return false;
    }

    const auto modifiers = event.modifiers() & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier);
    const auto key = event.key();
    const char* action = nullptr;

    if (modifiers == Qt::ControlModifier) {
      if (key == Qt::Key_D) {
        action = "half_down";
      } else if (key == Qt::Key_U) {
        action = "half_up";
      }
    } else if (modifiers == Qt::NoModifier) {
      const auto text = event.text();
      if (key == Qt::Key_Down || text == QLatin1StringView{"j"}) {
        action = "line_down";
      } else if (key == Qt::Key_Up || text == QLatin1StringView{"k"}) {
        action = "line_up";
      } else if (key == Qt::Key_PageDown || key == Qt::Key_Space || text == QLatin1StringView{"f"}) {
        action = "page_down";
      } else if (key == Qt::Key_PageUp || text == QLatin1StringView{"b"}) {
        action = "page_up";
      } else if (key == Qt::Key_Home || text == QLatin1StringView{"g"}) {
        action = "top";
      } else if (key == Qt::Key_End || text == QLatin1StringView{"G"}) {
        action = "bottom";
      }
    }

    if (action == nullptr) {
      return false;
    }

    scrollRequested(pane_id, QString::fromLatin1(action));
    return true;
  }

  void DocumentsController::measure(const QString& pane_id, qulonglong id, int rows) {
    const auto pane = pane_id.toULongLong();
    if (rows > 0 && store_.sessionMut().measureInline({.pane_id = pane, .id = id}, static_cast<std::uint32_t>(rows))) {
      measured(pane);
    }
  }

  void DocumentsController::publish(std::uint64_t pane_id) {
    changed(pane_id);
  }

}
