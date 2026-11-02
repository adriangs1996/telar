#include "qt/optical_text.hpp"
#include "font_smoothing.h"
#include <CoreText/CoreText.h>
#include <QFontMetricsF>
#include <QGlyphRun>
#include <QImage>
#include <QPainter>
#include <QQuickWindow>
#include <QSGSimpleTextureNode>
#include <QTextLayout>
#include <QtGui/private/qrawfont_p.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <span>
#include <stdexcept>
#include <vector>

namespace telar::gui::qt {
namespace {
constexpr CGFloat synthetic_italic_slant = 0.21256;
constexpr CGFloat synthetic_bold_divisor = 24;
constexpr CGFloat smoothing_margin = 1;
constexpr int maximum_channel = std::numeric_limits<std::uint8_t>::max();
constexpr int channel_rounding = maximum_channel / 2;
constexpr std::size_t alpha_bits = std::numeric_limits<std::uint8_t>::digits;

int compositeChannel(int foreground, int background, int alpha) noexcept {
  return ((foreground * alpha) + (background * (maximum_channel - alpha)) + channel_rounding) / maximum_channel;
}

QRgb compositePixel(QRgb background, QColor color, int alpha) noexcept {
  return qRgba(compositeChannel(color.red(), qRed(background), alpha),
               compositeChannel(color.green(), qGreen(background), alpha),
               compositeChannel(color.blue(), qBlue(background), alpha),
               alpha + (((qAlpha(background) * (maximum_channel - alpha)) + channel_rounding) / maximum_channel));
}

QSize physicalSize(QSizeF size, qreal scale) {
  const auto width = std::ceil(size.width() * scale);
  const auto height = std::ceil(size.height() * scale);
  constexpr auto largest_extent = std::numeric_limits<int>::max();
  if (!std::isfinite(scale) || scale <= 0 || !std::isfinite(width) || !std::isfinite(height) || width <= 0 || height <= 0 || width > largest_extent || height > largest_extent) {
    throw std::invalid_argument{"Invalid optical text raster dimensions"};
  }

  return {static_cast<int>(width), static_cast<int>(height)};
}

CGRect drawGlyphs(CGContextRef context, CTFontRef font, std::span<const CGGlyph> indexes, std::span<const CGPoint> positions, bool bold) {
  const auto stroke = CTFontGetSize(font) / synthetic_bold_divisor;
  CGContextSetTextDrawingMode(context, bold ? kCGTextFillStroke : kCGTextFill);
  CGContextSetLineWidth(context, stroke);
  const auto extra = (bold ? stroke / 2 : 0) + smoothing_margin;
  auto ink = CGRectNull;
  for (std::size_t index = 0; index < indexes.size(); ++index) {
    const auto bounds = CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationHorizontal, &indexes[index], nullptr, 1);
    if (CGRectIsEmpty(bounds)) {
      continue;
    }

    const auto left = std::floor(CGRectGetMinX(bounds) - extra);
    const auto bottom = std::floor(CGRectGetMinY(bounds) - extra);
    const auto right = std::ceil(CGRectGetMaxX(bounds) + extra);
    const auto top = std::ceil(CGRectGetMaxY(bounds) + extra);
    const auto clip = CGRectMake(positions[index].x + left, positions[index].y + bottom, right - left, top - bottom);
    ink = CGRectUnion(ink, clip);
    CGContextSaveGState(context);
    CGContextClipToRect(context, clip);
    CTFontDrawGlyphs(font, &indexes[index], &positions[index], 1, context);
    CGContextRestoreGState(context);
  }

  return ink;
}

}

struct OpticalText::State {
  struct Font {
    QRawFont source;
    std::shared_ptr<const __CTFont> native;
    unsigned synthesized = 0;
  };

  static constexpr std::size_t maximum_fonts = 32;
  QImage mask;
  QImage image;
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
  State(State &&) = delete;
  State &operator=(State &&) = delete;

  ~State() {
    if (context != nullptr) {
      CGContextRelease(context);
    }
  }

  Font *font(const QRawFont &source) {
    if (!source.isValid()) {
      return nullptr;
    }

    const auto found = std::ranges::find_if(fonts, [&source](const Font &font) {
      return font.source == source;
    });

    if (found != fonts.end()) {
      return &*found;
    }

    const auto *engine = QRawFontPrivate::get(source)->fontEngine;

    if (engine == nullptr || engine->type() != QFontEngine::Mac || engine->handle() == nullptr) {
      return nullptr;
    }

    const auto synthesized = static_cast<unsigned>(engine->synthesized());
    const auto skew = CGAffineTransformMake(1, 0, synthetic_italic_slant, 1, 0, 0);
    const auto *native = CTFontCreateCopyWithAttributes(
        static_cast<CTFontRef>(engine->handle()),
        source.pixelSize() * scale,
        (synthesized & static_cast<unsigned>(QFontEngine::SynthesizedItalic)) != 0 ? &skew : nullptr,
        nullptr);

    if (native == nullptr) {
      return nullptr;
    }

    if (fonts.size() == maximum_fonts) {
      fonts.clear();
    }

    fonts.push_back({
        .source = source,
        .native = {native, CFRelease},
        .synthesized = synthesized,
    });
    return &fonts.back();
  }

  void positionGlyphs(const QGlyphRun &run, QPointF origin) {
    const auto glyphs = run.glyphIndexes();
    const auto points = run.positions();
    if (glyphs.size() != points.size()) {
      throw std::invalid_argument{"Optical glyph indexes and positions must have the same length"};
    }

    indexes.resize(static_cast<std::size_t>(glyphs.size()));
    positions.resize(static_cast<std::size_t>(points.size()));
    for (qsizetype index = 0; index < glyphs.size(); ++index) {
      if (glyphs[index] > std::numeric_limits<CGGlyph>::max()) {
        throw std::out_of_range{"Optical glyph index exceeds the CoreText range"};
      }

      const auto offset = static_cast<std::size_t>(index);
      indexes[offset] = static_cast<CGGlyph>(glyphs[index]);
      positions[offset] = {
          .x = (origin.x() + points[index].x()) * scale,
          .y = mask.height() - ((origin.y() + points[index].y()) * scale),
      };
    }
  }

  void composite(QRect bounds, QColor color) {
    bounds = bounds.intersected(image.rect());
    const auto opacity = color.alpha();

    for (int row = bounds.top(); row <= bounds.bottom(); ++row) {
      const auto coverage = std::span{mask.scanLine(row), static_cast<std::size_t>(mask.width())};
      const auto pixels = std::span{image.scanLine(row), static_cast<std::size_t>(image.bytesPerLine())};
      int first = bounds.right() + 1;
      int last = bounds.left() - 1;

      for (int column = bounds.left(); column <= bounds.right(); ++column) {
        const auto offset = static_cast<std::size_t>(column);
        const auto alpha = ((coverage[offset] * opacity) + channel_rounding) / maximum_channel;

        if (alpha != 0) {
          const auto pixel = pixels.subspan(offset * sizeof(QRgb), sizeof(QRgb));
          QRgb previous = 0;
          std::memcpy(&previous, pixel.data(), sizeof(previous));
          const auto composite = compositePixel(previous, color, alpha);
          std::memcpy(pixel.data(), &composite, sizeof(composite));
          first = std::min(first, column);
          last = column;
        }

        coverage[offset] = 0;
      }

      if (first <= last) {
        ink = ink.united(QRect(first, row, last - first + 1, 1));
      }
    }
  }
};

OpticalText::OpticalText()
    : state_(std::make_unique<State>()) {}

OpticalText::~OpticalText() = default;

std::unique_ptr<OpticalText> OpticalText::create() {
  return std::make_unique<OpticalText>();
}

void OpticalText::begin(QSizeF size, qreal scale, std::uint8_t strength) {
  auto &self = *state_;
  const auto pixels = physicalSize(size, scale);

  if (self.scale != scale) {
    self.fonts.clear();
  }

  if (self.context == nullptr || self.mask.size() != pixels || self.strength != strength || self.scale != scale) {
    if (self.context != nullptr) {
      CGContextRelease(self.context);
      self.context = nullptr;
    }

    self.mask = QImage(pixels, QImage::Format_Alpha8);
    if (self.mask.isNull()) {
      throw std::runtime_error{"Unable to allocate optical terminal mask"};
    }

    self.mask.fill(0);
    auto *space = CGColorSpaceCreateWithName(kCGColorSpaceLinearGray);
    if (space == nullptr) {
      throw std::runtime_error{"Unable to create optical terminal color space"};
    }

    self.context = CGBitmapContextCreate(self.mask.bits(),
                                         pixels.width(),
                                         pixels.height(),
                                         alpha_bits,
                                         self.mask.bytesPerLine(),
                                         space,
                                         kCGImageAlphaOnly);
    CGColorSpaceRelease(space);

    if (self.context == nullptr) {
      throw std::runtime_error("Unable to allocate optical terminal mask");
    }

    telarFontSmoothing(self.context, true, strength);
  }

  self.scale = scale;
  self.strength = strength;
  if (self.image.size() != pixels) {
    self.image = QImage(pixels, QImage::Format_ARGB32_Premultiplied);
    if (self.image.isNull()) {
      throw std::runtime_error{"Unable to allocate optical terminal color image"};
    }
  }

  self.image.setDevicePixelRatio(scale);
  self.image.fill(Qt::transparent);
  self.mask.fill(0);
  self.ink = {};
}

QImage OpticalText::snapshot() const {
  return state_->image;
}

void OpticalText::add(const QTextLayout &layout, QPointF position, QColor color) {
  auto &self = *state_;
  if (self.context == nullptr) {
    throw std::logic_error{"Optical text must begin a raster before drawing"};
  }

  auto bounds = CGRectNull;

  for (const auto &run : layout.glyphRuns()) {
    const auto *font = self.font(run.rawFont());

    if (font == nullptr) {
      QPainter painter(&self.image);
      painter.setPen(color);
      painter.drawGlyphRun(position, run);
      self.ink =
          self.ink.united(QRectF(run.boundingRect().translated(position).topLeft() * self.scale,
                                 run.boundingRect().size() * self.scale)
                              .toAlignedRect());
      continue;
    }

    self.positionGlyphs(run, position);
    const bool bold = (font->synthesized & static_cast<unsigned>(QFontEngine::SynthesizedBold)) != 0;
    bounds = CGRectUnion(bounds, drawGlyphs(self.context, font->native.get(), self.indexes, self.positions, bold));
  }

  CGContextFlush(self.context);
  if (!CGRectIsNull(bounds)) {
    self.composite(QRectF{CGRectGetMinX(bounds), self.mask.height() - CGRectGetMaxY(bounds), CGRectGetWidth(bounds), CGRectGetHeight(bounds)}.toAlignedRect(), color);
  }

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

QSGNode *OpticalText::node(QQuickWindow &window, QPointF position) {
  const auto &self = *state_;
  const auto ink = self.ink.intersected(self.image.rect());
  if (ink.isEmpty()) {
    return nullptr;
  }

  std::unique_ptr<QSGTexture> texture{window.createTextureFromImage(self.image.copy(ink))};
  if (!texture) {
    return nullptr;
  }

  auto node = std::make_unique<QSGSimpleTextureNode>();
  node->setOwnsTexture(true);
  node->setTexture(texture.release());
  node->setRect(QRectF(position + QPointF(ink.topLeft()) / self.scale, QSizeF(ink.size()) / self.scale));

  return node.release();
}
}
