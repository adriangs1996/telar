#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include "font_asset.hpp"
#include "../core/memory.hpp"
#include <cstddef>
#include <span>
#include <array>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include <string_view>
#include "../platform/font.h"
#include <cstring>
#include "telar_client/serializers/telar_cells.hpp"
#include <optional>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <limits>
#include <stdexcept>
#include <type_traits>
#include <concepts>
#include <utility>
#include <bit>
#include <ghostty/vt/unicode.h>
#include <QColor>
#include <QPointF>
#include <QQuickWindow>
#include <QSGNode>
#include <QSizeF>
#include <QtCore/qtypes.h>

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

QSGNode *paintChromeIcon(QSGNode *previous, QQuickWindow &window, const ChromeIconPaint &paint);

}
