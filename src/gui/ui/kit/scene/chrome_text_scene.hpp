#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "tbc/view.hpp"
#include "ui/kit/fonts/font_collection.hpp"
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

#pragma once

import telar.gui.foundation.core;
import telar.gui.foundation.fonts;
import telar.gui.foundation.terminal;
import telar.base.ds;

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
    ds::Option<FontGrid> grid = ds::none;
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
    ds::Option<TextInkPlacement> placement = ds::none;
    ds::Option<Color> foreground = ds::none;
  };

  // Each result reuses the previous node or is a new one the caller adopts.
  tbc::val_a<QSGNode*> paintChromeText(tbc::val_a<QSGNode*> previous, QQuickWindow& window, const ChromeTextPaint& paint, const std::shared_ptr<const FontCollection>& collection);
  tbc::val_a<QSGNode*> paintTerminalText(tbc::val_a<QSGNode*> previous, QQuickWindow& window, const ChromeTextPaint& paint, const std::shared_ptr<const FontCollection>& collection, fonts::GlyphRasterization rasterization);

}
