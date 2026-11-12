#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#pragma once

#include <QObject>
#include <QPointer>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <cstdint>

namespace telar::gui::qt {

  class Application;

  // The document a pane's program shows natively (`telar render`), as the blocks QML lays out.
  // The session owns the decoded document; this projects it once per version, with all of its
  // text escaped into Qt rich text, so nothing a program wrote is read as markup.
  class DocumentView : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(NativeDocument)
    Q_PROPERTY(QObject *application READ application WRITE setApplication NOTIFY applicationChanged)
    Q_PROPERTY(QString paneId READ paneId WRITE setPaneId NOTIFY paneIdChanged)
    // 0 for the document that covers the pane; else one drawn in place of rows it stands for.
    Q_PROPERTY(qulonglong documentId READ documentId WRITE setDocumentId NOTIFY documentIdChanged)
    Q_PROPERTY(QVariantMap colors READ colors WRITE setColors NOTIFY colorsChanged)
    Q_PROPERTY(QString monoFamily READ monoFamily WRITE setMonoFamily NOTIFY monoFamilyChanged)
    Q_PROPERTY(bool shown READ shown NOTIFY documentChanged)
    // Each block: kind (paragraph, heading, code, rule, table, html), level, quote, list,
    // marker, callout, calloutTitle, opensCallout, tight, and by kind: html (rich text), text and
    // info (verbatim), or columns and rows (lists of cells, each with html and align).
    Q_PROPERTY(QVariantList blocks READ blocks NOTIFY documentChanged)

  public:
    explicit DocumentView(QObject *parent = nullptr);

    [[nodiscard]] QObject *application() const noexcept;
    void setApplication(QObject *application);
    [[nodiscard]] QString paneId() const;
    void setPaneId(const QString &identity);

    [[nodiscard]] qulonglong documentId() const noexcept {
      return document_id_;
    }

    void setDocumentId(qulonglong id);
    [[nodiscard]] QVariantMap colors() const;
    void setColors(const QVariantMap &colors);
    [[nodiscard]] QString monoFamily() const;
    void setMonoFamily(const QString &family);
    [[nodiscard]] bool shown() const noexcept;
    [[nodiscard]] QVariantList blocks() const;

    // Opens a link the document shows, when it is a web or mail address; other schemes, such as
    // file: or a custom handler, stay text.
    [[nodiscard]] Q_INVOKABLE bool openLink(const QString &target) const;

  signals:
    void applicationChanged();
    void paneIdChanged();
    void documentIdChanged();
    void colorsChanged();
    void monoFamilyChanged();
    void documentChanged();
    // A key asked the view to move: line_up, line_down, half_up, half_down, page_up, page_down,
    // top or bottom.
    void scrollRequested(const QString &action);

  private:
    void refresh();
    void project();

    QPointer<Application> application_;
    std::uint64_t pane_id_ = 0;
    std::uint64_t document_id_ = 0;
    QVariantMap colors_;
    QString mono_family_;
    bool shown_ = false;
    // The pane's document version projected, and the inputs it was projected with.
    std::uint64_t version_ = 0;
    bool stale_ = true;
    QVariantList blocks_;
  };

}
