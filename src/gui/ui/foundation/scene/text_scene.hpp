#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/memory.hpp"
#include "platform/font.h"
#include "tbc/view.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "ui/foundation/fonts/font_collection.hpp"
#include "ui/foundation/fonts/resident_fonts.hpp"
#include <QtCore/qsystemdetection.h>
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
#ifdef Q_OS_MACOS
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
#ifdef Q_OS_MACOS
#endif

import telar.gui.foundation.core;
import telar.gui.foundation.fonts;
import telar.gui.foundation.terminal;
import telar.base.ds;

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
    // The scene paints through the window, region `a`.
    explicit TextScene(tbc::view<QQuickWindow&, tbc::lt::a> window);
    ~TextScene() = default;
    // The layouts allocate from memory_, so the scene keeps its address.
    TextScene(const TextScene&) = delete;
    TextScene& operator=(const TextScene&) = delete;
    TextScene(TextScene&&) = delete;
    TextScene& operator=(TextScene&&) = delete;

    void configure(const FontConfiguration& font, FontGrid grid, const std::shared_ptr<const FontCollection>& collection);
    void begin(const QRectF& bounds, qreal scale, const QRectF& clip, std::unique_ptr<QSGNode> previous = {});
    // A prepared row's cells are lent again to each call that may paint them, so the scene keeps no
    // view of them.
    bool prepare(std::span<const CellValue> cells, fonts::RowTextRequest request);
    void addCell(std::span<const CellValue> cells, std::size_t column, const QFont& font, Color foreground, fonts::GlyphStyle style);
    void appendInline(std::span<const CellValue> cells, std::unique_ptr<QSGNode> node);
    void add(const QString& text, const QFont& font, const QTextCharFormat& format, TextPlacement placement);
    // The result is the text's node, now a child of the parent.
    tbc::view<QSGNode*, tbc::lt::a> append(tbc::view<QSGNode&, tbc::lt::a> parent, std::span<const CellValue> cells = {});

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
    static void appendChunk(QSGNode& text, QSGNode* next_chunk, std::unique_ptr<QSGNode> node);
    // Paints one chunk through the scene's chunk cursor alone, as Rust splits a borrow of self: what it
    // paints views the row layout beside it. The result is the node to append, or none when the
    // previous chunk was painted in place.
    static std::unique_ptr<QSGNode> paintChunk(QSGNode*& next_chunk, QQuickWindow& window, const std::shared_ptr<const FontCollection>& collection, fonts::GlyphRasterization rasterization, const ChromeTextPaint& paint);
    void flushCells(std::span<const CellValue> cells);
    void addFallbackCells(const Batch& batch, std::span<const CellValue> cells);
    void addQtText(const QString& text, const QFont& font, const QTextCharFormat& format, TextPlacement placement);

    tbc::view<QQuickWindow&, tbc::lt::a> window_;
    SystemAllocator memory_;
    MemoryAdapter<SystemAllocator> adapter_{memory_};
    fonts::TextLayout<ConcurrentMemory> layout_;
    fonts::RowTextLayout<ConcurrentMemory> row_;
    ds::Option<Batch> batch_;
    std::shared_ptr<const FontCollection> collection_;
    std::shared_ptr<ResidentFonts> fonts_;
    tbc::view<std::shared_ptr<ChromeGlyphImages<ResidentFonts, false>>, tbc::lt::a> resident_glyphs_;
    tbc::view<std::shared_ptr<ChromeGlyphImages<ResidentFonts, true>>, tbc::lt::a> optical_glyphs_;
    FontGrid grid_;
    fonts::GlyphRasterization rasterization_;
    QRectF bounds_;
    QRectF clip_;
    qreal scale_ = 1;
#ifdef Q_OS_MACOS
    std::unique_ptr<OpticalText> optical_;
#endif
    std::unique_ptr<QSGNode> text_;
    QSGNode* next_chunk_ = nullptr;
    std::uint64_t revision_ = 0;
  };

}
