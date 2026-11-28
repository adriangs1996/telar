export module telar.gui.ui.app.panes.documents:document_view;

import std;
import telar.gui.qt;
import :documents_controller;

export namespace telar::gui::qt {

  // The document a pane's program shows natively (`telar render`), as the blocks QML lays out.
  // The session owns the decoded document; this projects it once per version, with all of its
  // text escaped into Qt rich text, so nothing a program wrote is read as markup.
  class [[qt::object, qt_qml_named("NativeDocument")]] DocumentView : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    // 0 for the document that covers the pane; else one drawn in place of rows it stands for.
    // Each block: kind (paragraph, heading, code, rule, table, html), level, quote, list,
    // marker, callout, calloutTitle, opensCallout, tight, and by kind: html (rich text), text and
    // info (verbatim), or columns and rows (lists of cells, each with html and align).
    explicit DocumentView(QObject* parent = nullptr);

    [[nodiscard]] DocumentsController* controller() const noexcept;
    void setController(DocumentsController* controller);
    [[nodiscard]] QString paneId() const;
    void setPaneId(const QString& identity);

    [[tbc::hot_path]] [[nodiscard]] inline qulonglong documentId() const noexcept {
      return document_id_;
    }

    void setDocumentId(qulonglong id);
    [[nodiscard]] QVariantMap colors() const;
    void setColors(const QVariantMap& colors);
    [[nodiscard]] QString monoFamily() const;
    void setMonoFamily(const QString& family);
    [[nodiscard]] bool shown() const noexcept;
    [[nodiscard]] QVariantList blocks() const;

    // Opens a link the document shows, when it is a web or mail address; other schemes, such as
    // file: or a custom handler, stay text.
    [[nodiscard]] [[qt::invokable]] bool openLink(const QString& target) const;

    [[qt::signal]] void controllerChanged();
    [[qt::signal]] void paneIdChanged();
    [[qt::signal]] void documentIdChanged();
    [[qt::signal]] void colorsChanged();
    [[qt::signal]] void monoFamilyChanged();
    [[qt::signal]] void documentChanged();
    // A key asked the view to move: line_up, line_down, half_up, half_down, page_up, page_down,
    // top or bottom.
    [[qt::signal]] void scrollRequested(const QString& action);

  private:
    void refresh();
    void project();

    QPointer<DocumentsController> controller_;
    std::uint64_t pane_id_ = 0;
    std::uint64_t document_id_ = 0;
    QVariantMap colors_;
    QString mono_family_;
    bool shown_ = false;
    // The pane's document version projected, and the inputs it was projected with.
    std::uint64_t version_ = 0;
    bool stale_ = true;
    QVariantList blocks_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("controller", &DocumentView::controller).withWrite(&DocumentView::setController).withNotify(&DocumentView::controllerChanged),
        telar::qt::property("paneId", &DocumentView::paneId).withWrite(&DocumentView::setPaneId).withNotify(&DocumentView::paneIdChanged),
        telar::qt::property("documentId", &DocumentView::documentId).withWrite(&DocumentView::setDocumentId).withNotify(&DocumentView::documentIdChanged),
        telar::qt::property("colors", &DocumentView::colors).withWrite(&DocumentView::setColors).withNotify(&DocumentView::colorsChanged),
        telar::qt::property("monoFamily", &DocumentView::monoFamily).withWrite(&DocumentView::setMonoFamily).withNotify(&DocumentView::monoFamilyChanged),
        telar::qt::property("shown", &DocumentView::shown).withNotify(&DocumentView::documentChanged),
        telar::qt::property("blocks", &DocumentView::blocks).withNotify(&DocumentView::documentChanged)
    );
  };

}
