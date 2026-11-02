#pragma once

#include "core/configuration.hpp"
#include "core/memory.hpp"
#include "font_collection.hpp"
#include "fonts/font_role.hpp"
#include "fonts/glyph_bitmap_view.hpp"
#include "fonts/row_text_layout.hpp"
#include "fonts/text_layout.hpp"
#include "resident_fonts.hpp"
#include "terminal/font_grid.hpp"
#include <QtCore/qsystemdetection.h>
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
#include <cstdint>
#include <memory>

namespace telar::gui::qt {

template <fonts::FontProvider FontSet>
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

  void configure(const FontConfiguration &font, FontGrid grid, const std::shared_ptr<const FontCollection> &collection);
  void begin(const QRectF &bounds, qreal scale, const QRectF &clip, std::unique_ptr<QSGNode> previous = {});
  bool prepare(std::span<const CellValue> cells, fonts::RowTextRequest request);
  void addCell(std::size_t column, const QFont &font, Color foreground, fonts::GlyphStyle style);
  void appendInline(std::unique_ptr<QSGNode> node);
  void add(const QString &text, const QFont &font, const QTextCharFormat &format, TextPlacement placement);
  // Detach the returned text root before passing it to begin; optical nodes return null.
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
  std::shared_ptr<ChromeGlyphImages<ResidentFonts>> resident_glyphs_;
  FontGrid grid_;
  QRectF bounds_;
  QRectF clip_;
  qreal scale_ = 1;
#ifdef Q_OS_MACOS
  std::unique_ptr<OpticalText> optical_;
#endif
  std::unique_ptr<QSGNode> text_;
  QSGNode *next_chunk_ = nullptr;
  std::uint64_t revision_ = 0;
#ifdef Q_OS_MACOS
  QPointF origin_;
  std::uint8_t strength_ = FontConfiguration::maximum_thicken_strength;
#endif
};

}
