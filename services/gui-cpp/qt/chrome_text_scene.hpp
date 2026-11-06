#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include "font_collection.hpp"
#include <concepts>
#include <utility>
#include <span>
#include <limits>
#include <algorithm>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include <stdexcept>
#include <hb.h>
#include "../core/memory.hpp"
#include <bit>
#include <freetype/freetype.h>
#include <memory>
#include "../platform/font.h"
#include <cstring>
#include <type_traits>
#include <ghostty/vt/unicode.h>
#include <QColor>
#include <QPointF>
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QSizeF>
#include <QtCore/qnamespace.h>
#include <QtCore/qtypes.h>

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

QSGNode *paintChromeText(QSGNode *previous, QQuickWindow &window, const ChromeTextPaint &paint, const std::shared_ptr<const FontCollection> &collection);
QSGNode *paintTerminalText(QSGNode *previous, QQuickWindow &window, const ChromeTextPaint &paint, const std::shared_ptr<const FontCollection> &collection, fonts::GlyphRasterization rasterization);

}
