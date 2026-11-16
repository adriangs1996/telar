#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "core/memory.hpp"
#include "platform/font.h"
#include "tbc/view.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "ui/fonts/font_asset.hpp"
#include <QColor>
#include <QPointF>
#include <QQuickWindow>
#include <QSGNode>
#include <QSizeF>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <bit>
#include <chrono>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <freetype/freetype.h>
#include <ghostty/vt/unicode.h>
#include <hb.h>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <type_traits>
#include <utility>

#pragma once

import telar.gui.core.metrics;
import telar.gui.fonts.row_text_layout;

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
  tbc::view<QSGNode*, tbc::lt::a> paintChromeIcon(tbc::view<QSGNode*, tbc::lt::a> previous, QQuickWindow& window, const ChromeIconPaint& paint);

}
