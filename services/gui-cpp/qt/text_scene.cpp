#include "text_scene.hpp"
#include "chrome_glyph_images.hpp"
#include "chrome_text_scene.hpp"
#include "core/color.hpp"
#include "core/configuration.hpp"
#include "font_collection.hpp"
#include "fonts/font_role.hpp"
#include "fonts/glyph_bitmap_view.hpp"
#include "fonts/row_text_layout.hpp"
#include "projection.hpp"
#include "resident_fonts.hpp"
#include "scene_nodes.hpp"
#include "terminal/font_grid.hpp"
#include "terminal/screen.hpp"
#include "ui/workbench/optical_text.hpp"
#include <QBrush>
#include <QFont>
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QSGTextNode>
#include <QString>
#include <QTextCharFormat>
#include <QTextLayout>
#include <QTextOption>
#include <QtCore/qnamespace.h>
#include <QtCore/qtypes.h>
#include <cstddef>
#include <exception>
#include <memory>
#include <span>
#include <stdexcept>
#include <utility>

namespace telar::gui::qt {

TextScene::TextScene(QQuickWindow &window)
    : window_(window),
      layout_(memory_),
      row_(memory_) {}

void TextScene::configure(const FontConfiguration &font, FontGrid grid, const std::shared_ptr<const FontCollection> &collection) {
  if (!font.thicken) {
    optical_.reset();
  } else if (!optical_) {
    optical_ = workbench::OpticalText::create();
  }

  strength_ = font.thicken_strength;
  grid_ = grid;
  collection_ = collection;
  fonts_ = ResidentFonts::shared(collection_);
  resident_glyphs_ = ChromeGlyphImages<ResidentFonts>::shared(window_, fonts_);
  row_.resetFont();
}

void TextScene::begin(const QRectF &bounds, qreal scale, const QRectF &clip, std::unique_ptr<QSGNode> previous) {
  batch_.reset();
  bounds_ = bounds;
  clip_ = clip;
  scale_ = scale;
  next_chunk_ = nullptr;
  if (optical_) {
    text_.reset();
    const auto overhang = bounds.height();
    const auto raster = bounds.adjusted(-overhang, -overhang, overhang, overhang);
    origin_ = raster.topLeft();
    optical_->begin(raster.size(), scale, strength_);
  } else {
    ++revision_;
    text_ = previous ? std::move(previous) : std::make_unique<QSGNode>();
    next_chunk_ = text_->firstChild();
  }
}

bool TextScene::prepare(std::span<const CellValue> cells, fonts::RowTextRequest request) {
  if (optical_) {
    return false;
  }

  try {
    row_.shape(*fonts_, cells, request);
    row_source_ = cells;
    return true;
  } catch (const std::exception &) {
    return false;
  }
}

void TextScene::addCell(std::size_t column, const QFont &font, Color foreground, fonts::GlyphStyle style) {
  const auto range = row_.cell(column);
  if (range.span_count == 0) {
    return;
  }

  if (batch_ && (batch_->foreground != foreground || batch_->style != style)) {
    flushCells();
  }

  if (!batch_) {
    batch_ = Batch{.first_column = column, .last_column = column, .first_span = range.first_span, .span_count = 0, .foreground = foreground, .style = style, .font = font};
  }

  batch_->last_column = column;
  batch_->span_count += range.span_count;
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
  if (next_chunk_ != nullptr) {
    text_->insertChildNodeBefore(node.release(), next_chunk_);
  } else {
    adoptSceneNode(*text_, std::move(node));
  }
}

void TextScene::paintChunk(const ChromeTextPaint &paint) {
  auto *previous = next_chunk_;
  if (previous != nullptr) {
    next_chunk_ = previous->nextSibling();
  }

  auto *painted = paintChromeText(previous, window_, paint, collection_);
  if (painted != previous) {
    appendChunk(std::unique_ptr<QSGNode>{painted});
  }
}

void TextScene::flushCells() {
  if (!batch_) {
    return;
  }

  const auto batch = std::move(*batch_);
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
  paint.placement = TextInkPlacement{.origin = bounds_.topLeft(), .baseline = grid_.baseline / scale_, .clip = clip_};
  try {
    paintChunk(paint);
  } catch (const std::runtime_error &) {
    addFallbackCells(batch);
  }
}

void TextScene::addFallbackCells(const Batch &batch) {
  QTextCharFormat format;
  format.setForeground(toQColor(batch.foreground));
  for (auto column = batch.first_column; column <= batch.last_column; ++column) {
    if (row_.cell(column).span_count == 0) {
      continue;
    }

    const QPointF origin{bounds_.x() + (static_cast<qreal>(column) * grid_.width / scale_), bounds_.y()};
    addQtText(QString::fromUtf8(row_source_[column].utf8()), batch.font, format, {.origin = origin, .baseline = grid_.baseline / scale_, .style = batch.style});
  }
}

void TextScene::appendInline(std::unique_ptr<QSGNode> node) {
  flushCells();
  const auto previous = takeChunk();
  appendChunk(std::move(node));
}

void TextScene::add(const QString &text, const QFont &font, const QTextCharFormat &format, TextPlacement placement) {
  if (optical_) {
    addQtText(text, font, format, placement);
    return;
  }

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
    paintChunk(paint);
  } catch (const std::runtime_error &) {
    addQtText(text, font, format, placement);
  }
}

void TextScene::addQtText(const QString &text, const QFont &font, const QTextCharFormat &format, TextPlacement placement) {
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

  if (optical_) {
    optical_->add(layout, placement.origin - origin_, format.foreground().color());
  } else {
    const auto previous = takeChunk();
    std::unique_ptr<QSGTextNode> node{window_.createTextNode()};
    node->setRenderType(QSGTextNode::NativeRendering);
    node->addTextLayout(placement.origin, &layout);
    appendChunk(std::move(node));
  }
}

QSGNode *TextScene::append(QSGNode &parent) {
  flushCells();
  if (optical_) {
    std::unique_ptr<QSGNode> node{optical_->node(window_, origin_)};
    if (node) {
      adoptSceneNode(parent, std::move(node));
    }

    return nullptr;
  }

  while (next_chunk_ != nullptr) {
    const auto discarded = takeChunk();
  }

  return &adoptSceneNode(parent, std::move(text_));
}

}
