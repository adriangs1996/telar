#include "../../ui/workbench/optical_text.hpp"
#include "font_smoothing.h"
#include <CoreText/CoreText.h>
// Private: the CoreText font behind each of Qt's raw fonts. No public API gives it, so this may
// need adjusting when Qt changes.
#include <QtGui/private/qrawfont_p.h>
#include <QFontMetricsF>
#include <QGlyphRun>
#include <QImage>
#include <QPainter>
#include <QQuickWindow>
#include <QSGSimpleTextureNode>
#include <QTextLayout>
#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <vector>

namespace workbench {
  namespace {
    // Qt synthesizes a missing italic by slanting 12 degrees: tan(12°).
    constexpr CGFloat synthetic_italic_slant = 0.21256;
    // Qt synthesizes a missing bold by stroking the outline this wide per point of size.
    constexpr CGFloat synthetic_bold_stroke = 1.0 / 24;
    // Device pixels around a run's bounds that antialiasing can reach.
    constexpr qreal antialias_margin = 2;

    struct State {
      struct Font {
        QRawFont source;
        std::shared_ptr<const __CTFont> native;
        int synthesized = 0;
      };

      static constexpr std::size_t maximum_fonts = 32;
      QImage mask, image;
      CGContextRef context = nullptr;
      std::vector<Font> fonts;
      std::vector<CGGlyph> indexes;
      std::vector<CGPoint> positions;
      qreal scale = 0;
      std::uint8_t strength = 0;
      QRect ink;

      State() = default;
      State(const State &) = delete;
      State &operator=(const State &) = delete;

      ~State() {
        if (context) {
          CGContextRelease(context);
        }
      }

      Font *font(const QRawFont &source) {
        const auto found = std::ranges::find_if(fonts, [&source](const Font &font) {
          return font.source == source;
        });

        if (found != fonts.end()) {
          return &*found;
        }

        auto *engine = QRawFontPrivate::get(source)->fontEngine;

        if (!engine || engine->type() != QFontEngine::Mac || !engine->handle()) {
          return nullptr;
        }

        const auto synthesized = engine->synthesized();
        auto skew = CGAffineTransformMake(1, 0, synthetic_italic_slant, 1, 0, 0);
        auto native = CTFontCreateCopyWithAttributes(
            static_cast<CTFontRef>(engine->handle()),
            source.pixelSize() * scale,
            synthesized & QFontEngine::SynthesizedItalic ? &skew : nullptr,
            nullptr);

        if (!native) {
          return nullptr;
        }

        if (fonts.size() == maximum_fonts) {
          fonts.clear();
        }

        fonts.push_back({source,
                         {native,
                          [](CTFontRef font) {
                            CFRelease(font);
                          }},
                         synthesized});
        return &fonts.back();
      }

      // The shared alpha mask controls optical weight. Color is applied afterwards, so strength
      // never fades text or changes the grid. Only the shaped fragment's bounds are composited.
      void composite(QRect bounds, QColor color) {
        bounds = bounds.intersected(image.rect());
        const auto opacity = color.alpha();

        for (int y = bounds.top(); y <= bounds.bottom(); ++y) {
          auto *coverage = mask.scanLine(y);
          auto *pixels = reinterpret_cast<QRgb *>(image.scanLine(y));
          int first = bounds.right() + 1, last = bounds.left() - 1;

          for (int x = bounds.left(); x <= bounds.right(); ++x) {
            const auto alpha = (coverage[x] * opacity + 127) / 255;

            if (alpha) {
              const auto previous = pixels[x];
              const auto behind = 255 - alpha;
              pixels[x] = qRgba((color.red() * alpha + qRed(previous) * behind + 127) / 255,
                                (color.green() * alpha + qGreen(previous) * behind + 127) / 255,
                                (color.blue() * alpha + qBlue(previous) * behind + 127) / 255,
                                alpha + (qAlpha(previous) * behind + 127) / 255);
              first = std::min(first, x);
              last = x;
            }

            coverage[x] = 0;
          }

          if (first <= last) {
            ink = ink.united(QRect(first, y, last - first + 1, 1));
          }
        }
      }
    };

    // CoreText draws the glyphs into an alpha mask with the GUI's font smoothing, so strength
    // controls optical weight as in the GUI's glyph atlas.
    class CoreTextOpticalText final : public OpticalText {
    public:
      void begin(QSizeF size, qreal scale, std::uint8_t strength) override;
      void add(const QTextLayout &layout, QPointF position, QColor color) override;
      QSGNode *node(QQuickWindow &window, QPointF position) override;

    private:
      State state_;
    };
  } // namespace

  std::unique_ptr<OpticalText> OpticalText::create() {
    return std::make_unique<CoreTextOpticalText>();
  }

  void CoreTextOpticalText::begin(QSizeF size, qreal scale, std::uint8_t strength) {
    auto &self = state_;
    const QSize pixels(std::max(1, qCeil(size.width() * scale)),
                       std::max(1, qCeil(size.height() * scale)));

    if (self.scale != scale) {
      self.fonts.clear();
    }

    if (self.mask.size() != pixels || self.strength != strength || self.scale != scale) {
      if (self.context) {
        CGContextRelease(self.context);
        self.context = nullptr;
      }

      self.mask = QImage(pixels, QImage::Format_Alpha8);
      self.mask.fill(0);
      auto space = CGColorSpaceCreateWithName(kCGColorSpaceLinearGray);
      self.context = CGBitmapContextCreate(self.mask.bits(),
                                           pixels.width(),
                                           pixels.height(),
                                           8,
                                           self.mask.bytesPerLine(),
                                           space,
                                           kCGImageAlphaOnly);
      CGColorSpaceRelease(space);

      if (!self.context) {
        throw std::runtime_error("Unable to allocate optical terminal mask");
      }

      telar_font_smoothing(self.context, true, strength);
    }

    self.scale = scale;
    self.strength = strength;
    if (self.image.size() != pixels) {
      self.image = QImage(pixels, QImage::Format_ARGB32_Premultiplied);
    }

    self.image.setDevicePixelRatio(scale);
    self.image.fill(Qt::transparent);
    self.mask.fill(0);
    self.ink = {};
  }

  void CoreTextOpticalText::add(const QTextLayout &layout, QPointF position, QColor color) {
    auto &self = state_;
    QRectF bounds;
    qreal margin = antialias_margin;

    for (const auto &run : layout.glyphRuns()) {
      auto *font = self.font(run.rawFont());

      if (!font) {
        QPainter painter(&self.image);
        painter.setPen(color);
        painter.drawGlyphRun(position, run);
        self.ink =
            self.ink.united(QRectF(run.boundingRect().translated(position).topLeft() * self.scale,
                                   run.boundingRect().size() * self.scale)
                                .toAlignedRect());
        continue;
      }

      const auto glyphs = run.glyphIndexes();
      const auto points = run.positions();
      self.indexes.resize(glyphs.size());
      self.positions.resize(points.size());

      for (qsizetype index = 0; index < glyphs.size(); ++index) {
        self.indexes[index] = static_cast<CGGlyph>(glyphs[index]);
        self.positions[index] = {(position.x() + points[index].x()) * self.scale,
                                 self.mask.height() -
                                     (position.y() + points[index].y()) * self.scale};
      }

      const bool bold = font->synthesized & QFontEngine::SynthesizedBold;
      CGContextSetTextDrawingMode(self.context, bold ? kCGTextFillStroke : kCGTextFill);
      const auto stroke = CTFontGetSize(font->native.get()) * synthetic_bold_stroke;
      CGContextSetLineWidth(self.context, stroke);
      CTFontDrawGlyphs(font->native.get(),
                       self.indexes.data(),
                       self.positions.data(),
                       glyphs.size(),
                       self.context);
      bounds = bounds.united(run.boundingRect().translated(position));
      margin = std::max(margin, std::ceil(stroke) + antialias_margin);
    }

    CGContextFlush(self.context);
    self.composite(QRectF(bounds.topLeft() * self.scale, bounds.size() * self.scale)
                       .adjusted(-margin, -margin, margin, margin)
                       .toAlignedRect(),
                   color);

    const auto formats = layout.formats();

    if (!formats.isEmpty() &&
        (formats.front().format.fontUnderline() || formats.front().format.fontStrikeOut() ||
         formats.front().format.fontOverline())) {
      const auto &format = formats.front().format;
      const QFontMetricsF metrics(layout.font());
      const auto line = layout.lineAt(0);
      const auto baseline = position.y() + line.y() + line.ascent();
      QPainter painter(&self.image);
      painter.setPen(QPen(color, metrics.lineWidth()));
      const auto rule = [&](qreal y) {
        painter.drawLine(QPointF(position.x(), y),
                         QPointF(position.x() + line.horizontalAdvance(), y));
        self.ink = self.ink.united(QRectF(position.x() * self.scale,
                                          (y - metrics.lineWidth()) * self.scale,
                                          line.horizontalAdvance() * self.scale,
                                          metrics.lineWidth() * 2 * self.scale)
                                       .toAlignedRect());
      };

      if (format.fontUnderline()) {
        rule(baseline + metrics.underlinePos());
      }

      if (format.fontStrikeOut()) {
        rule(baseline - metrics.strikeOutPos());
      }

      if (format.fontOverline()) {
        rule(baseline - metrics.ascent());
      }
    }
  }

  QSGNode *CoreTextOpticalText::node(QQuickWindow &window, QPointF position) {
    auto &self = state_;

    const auto ink = self.ink.intersected(self.image.rect());

    if (ink.isEmpty()) {
      return nullptr;
    }

    auto *node = new QSGSimpleTextureNode;
    node->setTexture(window.createTextureFromImage(self.image.copy(ink)));
    node->setOwnsTexture(true);
    node->setRect(
        QRectF(position + QPointF(ink.topLeft()) / self.scale, QSizeF(ink.size()) / self.scale));
    return node;
  }
} // namespace workbench
