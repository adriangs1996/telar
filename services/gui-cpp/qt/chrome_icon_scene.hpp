#pragma once

#include "core/geometry.hpp"
#include "font_asset.hpp"
#include "fonts/icon_layout.hpp"
#include <QColor>
#include <QPointF>
#include <QQuickWindow>
#include <QSGNode>
#include <QSizeF>
#include <QtCore/qtypes.h>
#include <cstdint>
#include <memory>
#include <span>

namespace telar::gui::qt {

struct ChromeIconPaint {
  std::span<const fonts::IconGlyph> glyphs;
  Rect ink;
  std::shared_ptr<const FontAsset> source;
  QPointF scene_origin;
  QSizeF bounds;
  QColor color;
  qreal scale = 1;
  float target_side = 0;
  std::uint16_t pixel_height = 0;
  std::uint64_t revision = 0;
};

QSGNode *paintChromeIcon(QSGNode *previous, QQuickWindow &window, const ChromeIconPaint &paint);

}
