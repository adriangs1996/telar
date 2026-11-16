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
#include "ui/foundation/fonts/font_collection.hpp"
#include <QColor>
#include <QPointF>
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QSizeF>
#include <QtCore/qnamespace.h>
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
import telar.gui.fonts.face;
import telar.gui.fonts.font_requests;
import telar.gui.fonts.row_text_layout;
import telar.gui.terminal.font_grid;

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

  // Each result reuses the previous node or is a new one the caller adopts.
  tbc::view<QSGNode*, tbc::lt::a> paintChromeText(tbc::view<QSGNode*, tbc::lt::a> previous, QQuickWindow& window, const ChromeTextPaint& paint, const std::shared_ptr<const FontCollection>& collection);
  tbc::view<QSGNode*, tbc::lt::a> paintTerminalText(tbc::view<QSGNode*, tbc::lt::a> previous, QQuickWindow& window, const ChromeTextPaint& paint, const std::shared_ptr<const FontCollection>& collection, fonts::GlyphRasterization rasterization);

}
