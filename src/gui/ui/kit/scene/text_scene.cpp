module telar.gui.ui.kit.scene;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.fonts;
import telar.gui.ui.kit.models;
import telar.gui.ui.kit.scene.optical_text;
import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.base.ds;

#ifdef Q_OS_MACOS
#endif

#ifdef Q_OS_MACOS
#endif

namespace telar::gui::qt {

  TextScene::TextScene(tbc::mut_a<QQuickWindow> window)
      : window_(window),
        layout_(adapter_),
        row_(adapter_) {}

  void TextScene::configure(const FontConfiguration& font, FontGrid grid, const std::shared_ptr<const FontCollection>& collection) {
    constexpr ds::Array hinting{fonts::GlyphHinting::native, fonts::GlyphHinting::light, fonts::GlyphHinting::full};

    rasterization_ = {.optical = font.thicken, .strength = font.thicken_strength, .hinting = hinting.at(std::to_underlying(font.hinting))};
#ifdef Q_OS_MACOS
    if (!rasterization_.coreText()) {
      optical_.reset();
    } else if (!optical_) {
      optical_ = OpticalText::create();
    }

#endif
    grid_ = grid;
    collection_ = collection;
    fonts_ = ResidentFonts::shared(collection_);
    if (rasterization_.configured()) {
      optical_glyphs_ = ChromeGlyphImages<ResidentFonts, true>::shared(window_, fonts_, rasterization_);
      resident_glyphs_.reset();
    } else {
      optical_glyphs_.reset();
      resident_glyphs_ = ChromeGlyphImages<ResidentFonts>::shared(window_, fonts_);
    }

    row_.resetFont();
  }

  void TextScene::begin(const QRectF& bounds, qreal scale, const QRectF& clip, std::unique_ptr<QSGNode> previous) {
    batch_.reset();
    bounds_ = bounds;
    clip_ = clip;
    scale_ = scale;
    ++revision_;
    text_ = previous ? std::move(previous) : std::make_unique<QSGNode>();
    next_chunk_ = text_->firstChild();
  }

  bool TextScene::prepare(std::span<const CellValue> cells, fonts::RowTextRequest request) {
    try {
      row_.shape(*fonts_, cells, request);
      return true;
    } catch (const std::exception&) {
      return false;
    }
  }

  void TextScene::addCell(std::span<const CellValue> cells, std::size_t column, const QFont& font, Color foreground, fonts::GlyphStyle style) {
    const auto range = row_.cell(column);
    if (range.span_count == 0) {
      return;
    }

    if (batch_ && (batch_->foreground != foreground || batch_->style != style)) {
      flushCells(cells);
    }

    if (!batch_) {
      batch_ = Batch{.first_column = column, .last_column = column, .first_span = range.first_span, .span_count = 0, .foreground = foreground, .style = style, .font = font};
    }

    batch_.getMut().last_column = column;
    batch_.getMut().span_count += range.span_count;
  }

  std::unique_ptr<QSGNode> TextScene::takeChunk() {
    std::unique_ptr<QSGNode> node{next_chunk_};
    if (node) {
      next_chunk_ = node->nextSibling();
      text_->removeChildNode(node.get());
    }

    return node;
  }

  void TextScene::appendChunk(std::unique_ptr<QSGNode> node) {
    appendChunk(*text_, next_chunk_, std::move(node));
  }

  void TextScene::appendChunk(QSGNode& text, QSGNode* next_chunk, std::unique_ptr<QSGNode> node) {
    if (next_chunk != nullptr) {
      text.insertChildNodeBefore(node.release(), next_chunk);
    } else {
      adoptSceneNode(text, std::move(node));
    }
  }

  std::unique_ptr<QSGNode> TextScene::paintChunk(QSGNode*& next_chunk, QQuickWindow& window, const std::shared_ptr<const FontCollection>& collection, fonts::GlyphRasterization rasterization, const ChromeTextPaint& paint) {
    auto* previous = next_chunk;
    if (previous != nullptr) {
      next_chunk = previous->nextSibling();
    }

    auto* painted = paintTerminalText(previous, window, paint, collection, rasterization);
    if (painted == previous) {
      return nullptr;
    }

    return std::unique_ptr<QSGNode>{painted};
  }

  void TextScene::flushCells(std::span<const CellValue> cells) {
    if (!batch_) {
      return;
    }

    const auto batch = std::move(batch_.getMut());

    batch_.reset();
    ChromeTextPaint paint;

    paint.glyphs = row_.glyphs();
    paint.spans = row_.spans().subspan(batch.first_span, batch.span_count);
    paint.grid = grid_;
    paint.pixel_height = grid_.pixel_height;
    paint.color = toQColor(batch.foreground);
    paint.foreground = batch.foreground;
    paint.scale = scale_;
    paint.revision = revision_;
    paint.style = batch.style;
    paint.placement = TextInkPlacement{.origin = bounds_.topLeft(), .baseline = static_cast<qreal>(grid_.baseline) / scale_, .clip = clip_};
    try {
      if (auto painted = paintChunk(next_chunk_, window_, collection_, rasterization_, paint)) {
        appendChunk(*text_, next_chunk_, std::move(painted));
      }
    } catch (const std::runtime_error&) {
      addFallbackCells(batch, cells);
    }
  }

  void TextScene::addFallbackCells(const Batch& batch, std::span<const CellValue> cells) {
    QTextCharFormat format;

    format.setForeground(toQColor(batch.foreground));
    const auto end = std::min(batch.last_column + 1, cells.size());

    for (auto column = batch.first_column; column < end; ++column) {
      if (row_.cell(column).span_count == 0) {
        continue;
      }

      const QPointF origin{bounds_.x() + (static_cast<qreal>(column) * grid_.width / scale_), bounds_.y()};

      addQtText(QString::fromUtf8(cells[column].utf8()), batch.font, format, {.origin = origin, .baseline = static_cast<qreal>(grid_.baseline) / scale_, .style = batch.style});
    }
  }

  void TextScene::appendInline(std::span<const CellValue> cells, std::unique_ptr<QSGNode> node) {
    flushCells(cells);
    const auto previous = takeChunk();

    appendChunk(std::move(node));
  }

  void TextScene::add(const QString& text, const QFont& font, const QTextCharFormat& format, TextPlacement placement) {
    try {
      const auto bytes = text.toUtf8();

      layout_.shape(*fonts_, {bytes.constData(), static_cast<std::size_t>(bytes.size())}, {.pixel_height = grid_.pixel_height, .preferred = fonts::FontRole::primary});
      ChromeTextPaint paint;

      paint.glyphs = layout_.glyphs();
      paint.spans = layout_.spans();
      paint.grid = grid_;
      paint.pixel_height = grid_.pixel_height;
      paint.color = format.foreground().color();
      paint.scale = scale_;
      paint.revision = revision_;
      paint.style = placement.style;
      paint.placement = TextInkPlacement{.origin = placement.origin, .baseline = placement.baseline, .clip = clip_};
      if (auto painted = paintChunk(next_chunk_, window_, collection_, rasterization_, paint)) {
        appendChunk(*text_, next_chunk_, std::move(painted));
      }
    } catch (const std::runtime_error&) {
      addQtText(text, font, format, placement);
    }
  }

  void TextScene::addQtText(const QString& text, const QFont& font, const QTextCharFormat& format, TextPlacement placement) {
    QTextLayout layout{text, font};
    QTextOption option;

    option.setTextDirection(Qt::LeftToRight);
    option.setWrapMode(QTextOption::NoWrap);
    layout.setTextOption(option);
    layout.setFormats({{.start = 0, .length = static_cast<int>(text.size()), .format = format}});
    layout.beginLayout();
    auto line = layout.createLine();

    line.setNumColumns(static_cast<int>(text.size()));
    line.setPosition({0, placement.baseline - line.ascent()});
    layout.endLayout();

#ifdef Q_OS_MACOS
    if (optical_) {
      const auto previous = takeChunk();
      const auto overhang = bounds_.height();
      const auto raster = bounds_.adjusted(-overhang, -overhang, overhang, overhang);

      optical_->begin(raster.size(), scale_, rasterization_.strength);
      optical_->add(layout, placement.origin - raster.topLeft(), format.foreground().color());
      if (std::unique_ptr<QSGNode> node{optical_->node(window_, raster.topLeft())}) {
        appendChunk(std::move(node));
      }
    } else
#endif
    {
      const auto previous = takeChunk();
      std::unique_ptr<QSGTextNode> node{window_.createTextNode()};

      node->setRenderType(QSGTextNode::NativeRendering);
      node->addTextLayout(placement.origin, &layout);
      appendChunk(std::move(node));
    }
  }

  tbc::val_a<QSGNode*> TextScene::append(tbc::mut_a<QSGNode> parent, std::span<const CellValue> cells) {
    flushCells(cells);

    while (next_chunk_ != nullptr) {
      const auto discarded = takeChunk();
    }

    return &adoptSceneNode(parent, std::move(text_));
  }

}
