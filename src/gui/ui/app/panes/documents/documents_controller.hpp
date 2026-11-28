#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/kit/store/store.hpp"
#include <QKeyEvent>
#include <QObject>
#include <QString>
#include <QtQml/qqmlregistration.h>
#include <cstdint>

#pragma once

import telar.gui.application;
import telar.base.memory.allocators;

namespace telar::gui::qt {

  // The documents a pane's program shows natively (`telar render`): the one that covers the pane
  // and the ones drawn in place of its rows.
  //
  // It reads the store. The window tells it when a pane's documents changed; the views of that
  // pane project them again. A key scrolls the document that covers its pane. When an inline
  // document takes rows of the pane's view, or gives them back, it asks the window to lay the
  // terminal out again.
  class DocumentsController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(DocumentsController)
    QML_UNCREATABLE("Use the window's documents")

  public:
    explicit DocumentsController(Store& store, QObject* parent = nullptr);
    ~DocumentsController() override = default;
    DocumentsController(const DocumentsController&) = delete;
    DocumentsController& operator=(const DocumentsController&) = delete;
    DocumentsController(DocumentsController&&) = delete;
    DocumentsController& operator=(DocumentsController&&) = delete;

    [[nodiscard]] const application::Pane<Memory>* pane(std::uint64_t pane_id) const noexcept;
    // While the pane shows a document, its scroll keys move the document; every other key, as
    // q or Ctrl-C, reaches the program that shows it.
    bool key(std::uint64_t pane_id, const QKeyEvent& event);
    // The view measured an inline document in `rows` rows of its own: the pane makes room for it.
    Q_INVOKABLE void measure(const QString& pane_id, qulonglong id, int rows);
    // The pane's documents changed.
    void publish(std::uint64_t pane_id);

  signals:
    void changed(qulonglong pane_id);
    // A key asked the document that covers the pane to move: line_up, line_down, half_up,
    // half_down, page_up, page_down, top or bottom.
    void scrollRequested(qulonglong pane_id, const QString& action);
    // An inline document took rows of the pane's view, or gave them back.
    void measured(qulonglong pane_id);

  private:
    Store& store_;
  };

}
