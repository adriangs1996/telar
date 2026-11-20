#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "tbc/view.hpp"
#include "ui/foundation/fonts/font_asset.hpp"
#include <QColor>
#include <QPointF>
#include <QQuickWindow>
#include <QSGNode>
#include <QSizeF>
#include <QtCore/qtypes.h>
#include <cstdint>
#include <memory>
#include <span>

#pragma once

import telar.gui.foundation.core;
import telar.gui.foundation.fonts;

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

  // The result reuses the previous node or is a new one the caller adopts.
  tbc::val_a<QSGNode*> paintChromeIcon(tbc::val_a<QSGNode*> previous, QQuickWindow& window, const ChromeIconPaint& paint);

}
