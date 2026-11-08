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
#include <algorithm>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/memory.hpp"
#include "font_collection.hpp"
#include <concepts>
#include <utility>
#include <span>
#include <limits>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include "../platform/font.h"
#include <cstring>
#include <cmath>
#include <stdexcept>
#include <type_traits>
#include <bit>
#include "../terminal/screen.hpp"
#include <ghostty/vt/unicode.h>
#include "resident_fonts.hpp"
#include <QtCore/qsystemdetection.h>
#if (defined(Q_OS_MACOS))
#include "optical_text.hpp"
#endif
#include <QFont>
#include <QPointF>
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QSGTextNode>
#include <QString>
#include <QTextCharFormat>

#pragma once
#include "core/memory.hpp"
#ifdef Q_OS_MACOS
#include "optical_text.hpp"
#endif


import telar.gui.core.metrics;
import telar.gui.fonts.face;
import telar.gui.fonts.font_requests;
import telar.gui.fonts.row_text_layout;
import telar.gui.terminal.font_grid;

namespace telar::gui::qt {

template <fonts::FontProvider FontSet, bool optical>
class ChromeGlyphImages;

struct ChromeTextPaint;

struct TextPlacement {
  QPointF origin;
  qreal baseline = 0;
  fonts::GlyphStyle style{};
};

class TextScene {
public:
  explicit TextScene(QQuickWindow &window);
  // The layouts allocate from memory_, so the scene keeps its address.
  TextScene(const TextScene &) = delete;
  TextScene &operator=(const TextScene &) = delete;

  void configure(const FontConfiguration &font, FontGrid grid, const std::shared_ptr<const FontCollection> &collection);
  void begin(const QRectF &bounds, qreal scale, const QRectF &clip, std::unique_ptr<QSGNode> previous = {});
  bool prepare(std::span<const CellValue> cells, fonts::RowTextRequest request);
  void addCell(std::size_t column, const QFont &font, Color foreground, fonts::GlyphStyle style);
  void appendInline(std::unique_ptr<QSGNode> node);
  void add(const QString &text, const QFont &font, const QTextCharFormat &format, TextPlacement placement);
  QSGNode *append(QSGNode &parent);

private:
  struct Batch {
    std::size_t first_column = 0;
    std::size_t last_column = 0;
    std::size_t first_span = 0;
    std::size_t span_count = 0;
    Color foreground;
    fonts::GlyphStyle style;
    QFont font;
  };

  std::unique_ptr<QSGNode> takeChunk();
  void appendChunk(std::unique_ptr<QSGNode> node);
  void paintChunk(const ChromeTextPaint &paint);
  void flushCells();
  void addFallbackCells(const Batch &batch);
  void addQtText(const QString &text, const QFont &font, const QTextCharFormat &format, TextPlacement placement);

  QQuickWindow &window_;
  SystemAllocator memory_;
  fonts::TextLayout<SystemAllocator> layout_;
  fonts::RowTextLayout<SystemAllocator> row_;
  std::span<const CellValue> row_source_;
  std::optional<Batch> batch_;
  std::shared_ptr<const FontCollection> collection_;
  std::shared_ptr<ResidentFonts> fonts_;
  std::shared_ptr<ChromeGlyphImages<ResidentFonts, false>> resident_glyphs_;
  std::shared_ptr<ChromeGlyphImages<ResidentFonts, true>> optical_glyphs_;
  FontGrid grid_;
  fonts::GlyphRasterization rasterization_;
  QRectF bounds_;
  QRectF clip_;
  qreal scale_ = 1;
#ifdef Q_OS_MACOS
  std::unique_ptr<OpticalText> optical_;
#endif
  std::unique_ptr<QSGNode> text_;
  QSGNode *next_chunk_ = nullptr;
  std::uint64_t revision_ = 0;
};

}
