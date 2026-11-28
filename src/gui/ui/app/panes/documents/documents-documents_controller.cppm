export module telar.gui.ui.app.panes.documents:documents_controller;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.store;
import telar.gui.application;
import telar.base.memory.allocators;

export namespace telar::gui::qt {

  // The documents a pane's program shows natively (`telar render`): the one that covers the pane
  // and the ones drawn in place of its rows.
  //
  // It reads the store. The window tells it when a pane's documents changed; the views of that
  // pane project them again. A key scrolls the document that covers its pane. When an inline
  // document takes rows of the pane's view, or gives them back, it asks the window to lay the
  // terminal out again.
  class [[qt::object, qt_qml_named("DocumentsController"), qt_qml_uncreatable("Use the window's documents")]] DocumentsController final : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);
    enum class QmlIsUncreatable : quint8 {
      yes = 1,
    };
    void qt_qmlMarker_uncreatable();

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
    [[qt::invokable]] void measure(const QString& pane_id, qulonglong id, int rows);
    // The pane's documents changed.
    void publish(std::uint64_t pane_id);

    [[qt::signal]] void changed(qulonglong pane_id);
    // A key asked the document that covers the pane to move: line_up, line_down, half_up,
    // half_down, page_up, page_down, top or bottom.
    [[qt::signal]] void scrollRequested(qulonglong pane_id, const QString& action);
    // An inline document took rows of the pane's view, or gave them back.
    [[qt::signal]] void measured(qulonglong pane_id);

  private:
    Store& store_;
  };

}
