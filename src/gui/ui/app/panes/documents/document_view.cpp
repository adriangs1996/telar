#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "document_view.hpp"
#include <QDesktopServices>
#include <QKeyEvent>
#include <QUrl>
#include <span>
#include <string_view>

import telar.render.document;

namespace telar::gui::qt {
  namespace {

    using render::Align;
    using render::BlockKind;
    using render::Callout;
    using render::Marker;
    using Document = render::Document<Memory>;

    QString fromUtf8(std::string_view text) {
      return QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()));
    }

    // A palette color the theme names, and the one used when the theme leaves it out.
    struct ColorRole {
      const char* name;
      const char* fallback;
    };

    QString color(const QVariantMap& colors, ColorRole role) {
      const auto value = colors.value(QLatin1StringView{role.name}).toString();

      return value.isEmpty() ? QString::fromLatin1(role.fallback) : value;
    }

    QString kindName(BlockKind kind) {
      switch (kind) {
      case BlockKind::paragraph:
        return QStringLiteral("paragraph");
      case BlockKind::heading:
        return QStringLiteral("heading");
      case BlockKind::code:
        return QStringLiteral("code");
      case BlockKind::rule:
        return QStringLiteral("rule");
      case BlockKind::table:
        return QStringLiteral("table");
      case BlockKind::html:
        return QStringLiteral("html");
      case BlockKind::count:
        break;
      }

      return {};
    }

    QString calloutName(Callout callout) {
      switch (callout) {
      case Callout::note:
        return QStringLiteral("note");
      case Callout::tip:
        return QStringLiteral("tip");
      case Callout::important:
        return QStringLiteral("important");
      case Callout::warning:
        return QStringLiteral("warning");
      case Callout::caution:
        return QStringLiteral("caution");
      default:
        return {};
      }
    }

    QString calloutTitle(Callout callout) {
      switch (callout) {
      case Callout::note:
        return QStringLiteral("Note");
      case Callout::tip:
        return QStringLiteral("Tip");
      case Callout::important:
        return QStringLiteral("Important");
      case Callout::warning:
        return QStringLiteral("Warning");
      case Callout::caution:
        return QStringLiteral("Caution");
      default:
        return {};
      }
    }

    QString marker(const render::Block& block) {
      switch (block.marker) {
      case Marker::bullet:
        return block.list % 2 == 1 ? QStringLiteral("•") : QStringLiteral("◦");
      case Marker::ordered:
        return QString::number(block.number) + QLatin1Char('.');
      case Marker::task_open:
        return QStringLiteral("☐");
      case Marker::task_done:
        return QStringLiteral("☑");
      case Marker::footnote:
        return QString::number(block.number) + QLatin1Char(':');
      default:
        return {};
      }
    }

    QString alignName(Align align) {
      switch (align) {
      case Align::center:
        return QStringLiteral("center");
      case Align::right:
        return QStringLiteral("right");
      default:
        return QStringLiteral("left");
      }
    }

    // A pane's own document (id 0) or one of its inline documents.
    struct DocumentKey {
      std::uint64_t pane_id = 0;
      std::uint64_t document_id = 0;
    };

    // Whether a document shows, and what changes when it does.
    struct DocumentState {
      bool shown = false;
      std::uint64_t version = 0;
    };

    // The document a view shows, with its state.
    tbc::val_a<const Document*> findDocument(tbc::val_a<const DocumentsController*> controller, DocumentKey key, DocumentState& state) {
      const auto* pane = controller == nullptr ? nullptr : controller->pane(key.pane_id);

      state = {};
      if (pane == nullptr) {
        return nullptr;
      }

      if (key.document_id == 0) {
        state = {.shown = pane->document_shown, .version = pane->document_version};
        return &pane->document;
      }

      using Inline = application::Pane<Memory>::InlineDocument;
      const auto* const found = std::ranges::find(pane->inline_documents, key.document_id, &Inline::id);
      if (found == pane->inline_documents.end()) {
        return nullptr;
      }

      // An inline document never changes once whole.
      state = {.shown = found->shown, .version = found->whole ? 1U : 0U};
      return &found->document;
    }

    // Writes runs as Qt rich text. Every byte of text and target is escaped; the only markup is
    // the fixed tags written here, and no tag loads a resource.
    class RichText {
    public:
      RichText(const Document& document, const QVariantMap& colors, const QString& mono)
          : document_(document),
            code_style_(QStringLiteral("font-family:'%1'; background-color:%2; color:%3;").arg(mono.toHtmlEscaped(), color(colors, {.name = "surface", .fallback = "#2a2a2a"}), color(colors, {.name = "teal", .fallback = "#8bd5ca"}))),
            link_style_(QStringLiteral("color:%1; text-decoration:underline;").arg(color(colors, {.name = "accent", .fallback = "#8aadf4"}))),
            muted_style_(QStringLiteral("color:%1;").arg(color(colors, {.name = "muted", .fallback = "#888888"}))) {}

      [[nodiscard]] QString runs(std::span<const render::Run> runs) const {
        QString html;

        for (std::size_t index = 0; index < runs.size(); ++index) {
          const auto& run = runs[index];
          const auto style = run.style;
          const bool link = (style & render::style::link) != 0;
          const bool opens_link = link && (index == 0 || runs[index - 1].target != run.target || (runs[index - 1].style & render::style::link) == 0);
          const bool closes_link = link && (index + 1 == runs.size() || runs[index + 1].target != run.target || (runs[index + 1].style & render::style::link) == 0);

          if (opens_link) {
            html += QStringLiteral("<a href=\"%1\" style=\"%2\">").arg(fromUtf8(document_.view(run.target)).toHtmlEscaped(), link_style_);
          }

          QString text = escape(fromUtf8(document_.view(run.text)));

          if ((style & render::style::image) != 0) {
            text = QStringLiteral("<span style=\"%1\">[image: %2]</span>").arg(muted_style_, text);
          }

          if ((style & monospaced_styles) != 0) {
            text = QStringLiteral("<span style=\"%1\">&nbsp;%2&nbsp;</span>").arg(code_style_, text);
          }

          if ((style & render::style::html) != 0) {
            text = QStringLiteral("<span style=\"%1\">%2</span>").arg(muted_style_, text);
          }

          if ((style & render::style::superscript) != 0) {
            text = QStringLiteral("<sup>%1</sup>").arg(text);
          }

          if ((style & render::style::strike) != 0) {
            text = QStringLiteral("<s>%1</s>").arg(text);
          }

          if ((style & render::style::emphasis) != 0) {
            text = QStringLiteral("<i>%1</i>").arg(text);
          }

          if ((style & render::style::strong) != 0) {
            text = QStringLiteral("<b>%1</b>").arg(text);
          }

          html += text;
          if (closes_link) {
            html += QStringLiteral("</a>");
          }
        }

        return html;
      }

    private:
      // Code and math read as one monospaced span.
      static constexpr std::uint16_t monospaced_styles = render::style::code | render::style::math;

      static QString escape(const QString& text) {
        return text.toHtmlEscaped().replace(QLatin1Char('\n'), QStringLiteral("<br/>"));
      }

      const Document& document_;
      QString code_style_;
      QString link_style_;
      QString muted_style_;
    };

    // A table's cells, a row of `block.columns` at a time.
    QVariantList tableRows(const Document& document, const render::Block& block, const RichText& rich) {
      QVariantList rows;
      QVariantList row;

      for (const auto& cell : document.cellsOf(block)) {
        row.append(QVariantMap{
            {QStringLiteral("html"), rich.runs(document.runsOf(cell))},
            {QStringLiteral("align"), alignName(cell.align)},
        });

        if (row.size() == block.columns) {
          rows.append(QVariant{row});
          row.clear();
        }
      }

      return rows;
    }

  }

  DocumentView::DocumentView(QObject* parent)
      : QObject(parent) {}

  DocumentsController* DocumentView::controller() const noexcept {
    return controller_;
  }

  void DocumentView::setController(DocumentsController* controller) {
    if (controller_ == controller) {
      return;
    }

    if (controller_ != nullptr) {
      disconnect(controller_, nullptr, this, nullptr);
    }

    controller_ = controller;
    if (controller_ != nullptr) {
      connect(controller_, &DocumentsController::changed, this, [this](qulonglong pane_id) {
        if (pane_id == pane_id_) {
          refresh();
        }
      });

      connect(controller_, &DocumentsController::scrollRequested, this, [this](qulonglong pane_id, const QString& action) {
        if (pane_id == pane_id_ && document_id_ == 0 && shown_) {
          emit scrollRequested(action);
        }
      });
    }

    stale_ = true;
    refresh();
    emit controllerChanged();
  }

  QString DocumentView::paneId() const {
    return QString::number(pane_id_);
  }

  void DocumentView::setPaneId(const QString& identity) {
    const auto next = identity.toULongLong();
    if (pane_id_ != next) {
      pane_id_ = next;
      stale_ = true;
      refresh();
      emit paneIdChanged();
    }
  }

  QVariantMap DocumentView::colors() const {
    return colors_;
  }

  void DocumentView::setColors(const QVariantMap& colors) {
    if (colors_ != colors) {
      colors_ = colors;
      stale_ = true;
      refresh();
      emit colorsChanged();
    }
  }

  QString DocumentView::monoFamily() const {
    return mono_family_;
  }

  void DocumentView::setMonoFamily(const QString& family) {
    if (mono_family_ != family) {
      mono_family_ = family;
      stale_ = true;
      refresh();
      emit monoFamilyChanged();
    }
  }

  bool DocumentView::shown() const noexcept {
    return shown_;
  }

  QVariantList DocumentView::blocks() const {
    return blocks_;
  }

  bool DocumentView::openLink(const QString& target) const { // NOLINT(readability-convert-member-functions-to-static): QML calls it on the instance, and moc has no static invokables
    const QUrl url{target, QUrl::StrictMode};
    const auto scheme = url.scheme().toLower();
    if (!url.isValid() || (scheme != QLatin1StringView{"https"} && scheme != QLatin1StringView{"http"} && scheme != QLatin1StringView{"mailto"})) {
      return false;
    }

    return QDesktopServices::openUrl(url);
  }

  void DocumentView::setDocumentId(qulonglong id) {
    if (document_id_ != id) {
      document_id_ = id;
      stale_ = true;
      refresh();
      emit documentIdChanged();
    }
  }

  void DocumentView::refresh() {
    DocumentState state;

    static_cast<void>(findDocument(controller_, {.pane_id = pane_id_, .document_id = document_id_}, state));
    if (state.shown == shown_ && state.version == version_ && !stale_) {
      return;
    }

    shown_ = state.shown;
    version_ = state.version;
    stale_ = false;
    if (shown_) {
      project();
    } else {
      blocks_.clear();
    }

    emit documentChanged();
  }

  void DocumentView::project() {
    DocumentState state;
    const auto& document = *findDocument(controller_, {.pane_id = pane_id_, .document_id = document_id_}, state);
    const RichText rich{document, colors_, mono_family_};

    blocks_.clear();
    blocks_.reserve(static_cast<qsizetype>(document.blocks.size()));
    for (const auto& block : document.blocks) {
      QVariantMap item{
          {QStringLiteral("kind"), kindName(block.kind)},
          {QStringLiteral("level"), block.level},
          {QStringLiteral("quote"), block.quote},
          {QStringLiteral("list"), block.list},
          {QStringLiteral("marker"), marker(block)},
          {QStringLiteral("callout"), calloutName(block.callout)},
          {QStringLiteral("calloutTitle"), calloutTitle(block.callout)},
          {QStringLiteral("opensCallout"), (block.flags & render::Block::opens_callout) != 0},
          {QStringLiteral("tight"), (block.flags & render::Block::tight) != 0},
      };

      switch (block.kind) {
      case BlockKind::paragraph:
      case BlockKind::heading:
        item.insert(QStringLiteral("html"), rich.runs(document.runsOf(block)));
        break;
      case BlockKind::code:
      case BlockKind::html:
        item.insert(QStringLiteral("text"), fromUtf8(document.view(render::Span{.offset = block.first, .size = block.count})));
        item.insert(QStringLiteral("info"), fromUtf8(document.view(block.info)));
        break;
      case BlockKind::table:
        item.insert(QStringLiteral("columns"), block.columns);
        item.insert(QStringLiteral("rows"), tableRows(document, block, rich));
        break;
      case BlockKind::rule:
      case BlockKind::count:
        break;
      }

      blocks_.append(item);
    }
  }

}
