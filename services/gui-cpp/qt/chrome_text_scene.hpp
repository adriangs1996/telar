#pragma once

#include "core/color.hpp"
#include "font_collection.hpp"
#include "fonts/font_role.hpp"
#include "fonts/glyph_bitmap_view.hpp"
#include "fonts/shaped_run_view.hpp"
#include "fonts/text_layout.hpp"
#include "terminal/font_grid.hpp"
#include <QColor>
#include <QPointF>
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QSizeF>
#include <QtCore/qnamespace.h>
#include <QtCore/qtypes.h>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>

namespace telar::gui::qt {

struct TextInkPlacement {
  QPointF origin;
  qreal baseline = 0;
  QRectF clip;
};

struct ChromeTextPaint {
  std::span<const fonts::ShapedGlyph> glyphs;
  std::span<const fonts::TextSpan> spans;
  FontMetrics metrics;
  std::optional<FontGrid> grid = std::nullopt;
  QPointF scene_origin;
  QSizeF bounds;
  QColor color;
  qreal scale = 1;
  qreal fade_width = 0;
  std::uint64_t revision = 0;
  std::uint16_t pixel_height = 0;
  std::int32_t advance = 0;
  Qt::Alignment horizontal_alignment = Qt::AlignLeft;
  bool whole_pixel_centering = false;
  bool emphasized = false;
  fonts::FontRole role = fonts::FontRole::regular;
  fonts::GlyphStyle style{};
  std::optional<TextInkPlacement> placement = std::nullopt;
  std::optional<Color> foreground = std::nullopt;
};

QSGNode *paintChromeText(QSGNode *previous, QQuickWindow &window, const ChromeTextPaint &paint, const std::shared_ptr<const FontCollection> &collection);

}
