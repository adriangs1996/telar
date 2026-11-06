#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "text_scene.hpp"
#include "chrome_glyph_images.hpp"
#include "chrome_text_scene.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <algorithm>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "font_collection.hpp"
#include <concepts>
#include <utility>
#include <span>
#include "../core/memory.hpp"
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include "../platform/font.h"
#include <cstring>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <type_traits>
#include <bit>
#include "../terminal/screen.hpp"
#include <ghostty/vt/unicode.h>
#include "projection.hpp"
#include "resident_fonts.hpp"
#include "scene_nodes.hpp"
#if (defined(Q_OS_MACOS))
#include "optical_text.hpp"
#endif
#include <QBrush>
#include <QFont>
#include <QPointF>
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
#include <exception>

#include "terminal/screen.hpp"
#ifdef Q_OS_MACOS
#include "optical_text.hpp"
#endif


import telar.gui.core.metrics;
import telar.gui.fonts.face;
import telar.gui.fonts.row_text_layout;
import telar.gui.terminal.font_grid;

namespace telar::gui::qt {

TextScene::TextScene(QQuickWindow &window)
    : window_(window),
      layout_(memory_),
      row_(memory_) {}

void TextScene::configure(const FontConfiguration &font, FontGrid grid, const std::shared_ptr<const FontCollection> &collection) {
#ifdef Q_OS_MACOS
  if (!font.thicken) {
    optical_.reset();
  } else if (!optical_) {
    optical_ = OpticalText::create();
  }
#endif
  rasterization_ = font.thicken ? fonts::GlyphRasterization{.optical = true, .strength = font.thicken_strength} : fonts::GlyphRasterization{};
  grid_ = grid;
  collection_ = collection;
  fonts_ = ResidentFonts::shared(collection_);
  if (rasterization_.optical) {
    optical_glyphs_ = ChromeGlyphImages<ResidentFonts, true>::shared(window_, fonts_, rasterization_);
    resident_glyphs_.reset();
  } else {
    optical_glyphs_.reset();
    resident_glyphs_ = ChromeGlyphImages<ResidentFonts>::shared(window_, fonts_);
  }

  row_.resetFont();
}

void TextScene::begin(const QRectF &bounds, qreal scale, const QRectF &clip, std::unique_ptr<QSGNode> previous) {
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

  auto *painted = paintTerminalText(previous, window_, paint, collection_, rasterization_);
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

QSGNode *TextScene::append(QSGNode &parent) {
  flushCells();

  while (next_chunk_ != nullptr) {
    const auto discarded = takeChunk();
  }

  return &adoptSceneNode(parent, std::move(text_));
}

}
