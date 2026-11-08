#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../core/memory.hpp"
#include "../platform/font.h"
#include <algorithm>
#include <cstring>
#include <span>
#include <cstddef>
#include <cstdint>
#include <memory>
#include "../qt/bundled_fonts.hpp"
#include "../qt/optical_text.hpp"
#include <QByteArray>
#include <QColor>
#include <QFile>
#include <QFont>
#include <QGuiApplication>
#include <QImage>
#include <QPainter>
#include <QPoint>
#include <QSizeF>
#include <QString>
#include <QTemporaryDir>
#include <QTextLayout>
#include <QtCore/qiodevicebase.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qtypes.h>
#include <QtGui/qglyphrun.h>
#include <QtGui/qrawfont.h>
#include <QtGui/qrgb.h>
#include <array>
#include <cstdlib>
#include <exception>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vector>
#include "../platform/macos/glyph_rasterizer.h"

#include "core/memory.hpp"
#include "qt/bundled_fonts.hpp"
#include "qt/optical_text.hpp"


import telar.gui.fonts.face;
import telar.gui.platform.private_file_stamp;

extern "C" {
#include "glyph_rasterizer.h"
#include "platform/font.h"
}

namespace {

constexpr std::uint32_t atlas_side = 512;
constexpr qreal image_extent = atlas_side;
constexpr int glyph_margin = 16;
constexpr int opaque_channel = std::numeric_limits<std::uint8_t>::max();

enum class GlyphStyle : std::uint8_t {
  regular,
  bold,
  italic,
  bold_italic,
};

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

class OriginalRasterizer {
public:
  explicit OriginalRasterizer(const QByteArray &font, std::uint8_t strength)
      : font_(font.cbegin(), font.cend()),
        native_pixels_(telar::gui::platform::GlyphRasterizer::requiredBytes(), std::uint8_t{}, telar::gui::AllocatorRef<std::uint8_t, telar::gui::SystemAllocator>{memory_}),
        native_(native_pixels_, font_, native_match_, strength),
        native_reference_(native_pixels_.size(), 0) {
    const telar_glyph_rasterizer_options options{
        .font = font_.data(),
        .font_len = font_.size(),
        .postscript = nullptr,
        .face_index = 0,
        .pixels = pixels_.data(),
        .side = atlas_side,
        .thicken = 1,
        .strength = strength,
        .variation = &variation_,
    };
    handle_.reset(telarGlyphRasterizerCreate(&options));
    require(handle_ != nullptr, "Original CoreText rasterizer initialization failed");
    auto native_options = options;
    native_options.pixels = native_reference_.data();
    native_options.side = telar_glyph_atlas_max_side;
    native_handle_.reset(telarGlyphRasterizerCreate(&native_options));
    require(native_handle_ != nullptr, "Native atlas reference initialization failed");
  }

  void select(std::uint32_t pixel_height) {
    require(telarGlyphRasterizerSelect(handle_.get(), pixel_height) == 0, "Original CoreText font selection failed");
    pixel_height_ = static_cast<std::uint16_t>(pixel_height);
    require(telarGlyphRasterizerSelect(native_handle_.get(), pixel_height) == 0, "Native atlas reference font selection failed");
  }

  void paint(std::uint32_t index, GlyphStyle style, QPoint origin, QImage &image) {
    telar_glyph_raster glyph{.index = index, .style = static_cast<std::uint32_t>(style), .x = 0, .y = 0, .width = 0, .height = 0, .left = 0, .top = 0};
    require(telarGlyphRasterizerMeasure(handle_.get(), &glyph) == 0, "Original CoreText glyph measurement failed");
    glyph.x = static_cast<std::uint32_t>(origin.x() + glyph.left);
    glyph.y = static_cast<std::uint32_t>(origin.y() - glyph.top);
    telarGlyphRasterizerDraw(handle_.get(), &glyph);
    const auto cached = native_.rasterize({.index = index, .pixel_height = pixel_height_, .style = {.bold = style == GlyphStyle::bold || style == GlyphStyle::bold_italic, .italic = style == GlyphStyle::italic || style == GlyphStyle::bold_italic}});
    require(cached.width == glyph.width && cached.height == glyph.height && cached.left == glyph.left && cached.top == glyph.top, "Cached native glyph metrics differ from the optical oracle");
    auto native_glyph = glyph;
    native_glyph.x = 0;
    native_glyph.y = 0;
    telarGlyphRasterizerDraw(native_handle_.get(), &native_glyph);
    for (std::size_t row = 0; row < cached.height; ++row) {
      const auto expected = std::span{native_reference_}.subspan(row * telar_glyph_atlas_max_side, glyph.width);
      require(std::ranges::equal(cached.row(row), expected), "Cached native glyph pixels differ from the canonical atlas reference");
    }

    for (std::uint32_t row = 0; row < glyph.height; ++row) {
      for (std::uint32_t column = 0; column < glyph.width; ++column) {
        const auto alpha = pixels_[((glyph.y + row) * atlas_side) + glyph.x + column];
        const auto x = origin.x() + glyph.left + static_cast<int>(column);
        const auto y = origin.y() - glyph.top + static_cast<int>(row);
        require(image.rect().contains(x, y), "Original glyph exceeded the comparison surface");
        image.setPixel(x, y, qRgba(alpha, alpha, alpha, alpha));
      }
    }
  }

private:
  std::vector<std::uint8_t> font_;
  telar::gui::SystemAllocator memory_;
  telar::gui::Vector<std::uint8_t, telar::gui::SystemAllocator> native_pixels_;
  telar::gui::fonts::FontMatch native_match_{};
  telar::gui::platform::GlyphRasterizer native_;
  std::vector<std::uint8_t> native_reference_;
  std::unique_ptr<telar_glyph_rasterizer, decltype(&telarGlyphRasterizerDestroy)> native_handle_{nullptr, telarGlyphRasterizerDestroy};
  std::uint16_t pixel_height_ = 0;
  std::array<std::uint8_t, static_cast<std::size_t>(atlas_side) * atlas_side> pixels_{};
  telar_font_variation variation_{};
  std::unique_ptr<telar_glyph_rasterizer, decltype(&telarGlyphRasterizerDestroy)> handle_{nullptr, telarGlyphRasterizerDestroy};
};

void shapeGlyph(QTextLayout &layout, const QString &text, int pixel_height, GlyphStyle style) {
  QFont font{QStringLiteral("JetBrains Mono")};
  font.setStyleName(QStringLiteral("Regular"));
  font.setPixelSize(pixel_height);
  font.setBold(style == GlyphStyle::bold || style == GlyphStyle::bold_italic);
  font.setItalic(style == GlyphStyle::italic || style == GlyphStyle::bold_italic);
  layout.setFont(font);
  layout.setText(text);
  layout.beginLayout();
  auto line = layout.createLine();
  line.setNumColumns(static_cast<int>(text.size()));
  line.setPosition({0, -line.ascent()});
  layout.endLayout();
}

void compareGlyph(telar::gui::qt::OpticalText &optical, OriginalRasterizer &original, const QTextLayout &layout, int scale, GlyphStyle style) {
  const auto runs = layout.glyphRuns();
  require(runs.size() == 1 && runs.front().glyphIndexes().size() == 1, "The optical oracle requires a single glyph");
  const auto &run = runs.front();
  const QPoint origin{glyph_margin, glyph_margin + layout.font().pixelSize()};
  optical.add(layout, origin, Qt::white);
  const auto actual = optical.snapshot();
  QImage expected{actual.size(), QImage::Format_ARGB32_Premultiplied};
  expected.setDevicePixelRatio(scale);
  expected.fill(Qt::transparent);
  original.paint(run.glyphIndexes().front(), style, origin * scale, expected);
  if (actual != expected) {
    QTemporaryDir directory;
    require(directory.isValid(), "Cannot create optical diagnostic directory");
    directory.setAutoRemove(false);
    actual.save(directory.filePath(QStringLiteral("actual.png")));
    expected.save(directory.filePath(QStringLiteral("expected.png")));
    std::cerr << "Glyph mismatch: scale=" << scale << " height=" << layout.font().pixelSize() << " style=" << static_cast<unsigned>(style) << " text=" << layout.text().toStdString() << " images=" << directory.path().toStdString() << '\n';
    throw std::runtime_error{"Optical text differs from the original CoreText glyph raster"};
  }
}

QImage coloredMask(QImage image, QColor color) {
  QPainter painter{&image};
  painter.setCompositionMode(QPainter::CompositionMode_SourceIn);
  painter.fillRect(image.rect(), color);
  painter.end();

  return image;
}

void verifySnapshotAndCompositing() {
  const auto optical = telar::gui::qt::OpticalText::create();
  constexpr int pixel_height = 32;
  constexpr std::uint8_t strength = 128;
  constexpr QPoint origin{glyph_margin, glyph_margin + pixel_height};
  constexpr QColor translucent_red{255, 0, 0, 128};
  constexpr QColor translucent_blue{0, 0, 255, 64};
  QTextLayout layout;
  shapeGlyph(layout, QStringLiteral("M"), pixel_height, GlyphStyle::regular);
  optical->begin({image_extent, image_extent}, 1, strength);
  optical->add(layout, origin, Qt::white);
  const auto mask = optical->snapshot();
  const auto preserved = mask.copy();
  auto expected = coloredMask(mask, translucent_red);
  const auto upper_layer = coloredMask(mask, translucent_blue);
  QPainter compositor{&expected};
  compositor.drawImage(QPoint{}, upper_layer);
  compositor.end();
  optical->begin({image_extent, image_extent}, 1, strength);
  optical->add(layout, origin, translucent_red);
  optical->add(layout, origin, translucent_blue);
  require(mask == preserved, "A retained optical snapshot must survive another raster batch");
  const auto actual = optical->snapshot();
  for (int row = 0; row < actual.height(); ++row) {
    for (int column = 0; column < actual.width(); ++column) {
      const auto difference = actual.pixel(column, row);
      const auto reference = expected.pixel(column, row);
      constexpr int channel_tolerance = 1;
      for (const auto delta : {qRed(difference) - qRed(reference), qGreen(difference) - qGreen(reference), qBlue(difference) - qBlue(reference), qAlpha(difference) - qAlpha(reference)}) {
        require(std::abs(delta) <= channel_tolerance, "Optical source-over must preserve premultiplied color and opacity");
      }
    }
  }
}

void verifyInvalidDimensions() {
  const auto optical = telar::gui::qt::OpticalText::create();
  constexpr std::array invalid_extents{0.0, -1.0, std::numeric_limits<qreal>::infinity(), std::numeric_limits<qreal>::quiet_NaN()};
  for (const auto extent : invalid_extents) {
    bool rejected = false;
    try {
      optical->begin({extent, image_extent}, 1, 0);
    } catch (const std::invalid_argument &) {
      rejected = true;
    }

    require(rejected, "Invalid optical dimensions must fail before bitmap allocation");
  }
}

std::size_t compareSize(telar::gui::qt::OpticalText &optical, OriginalRasterizer &original, std::uint8_t strength, int scale, int pixel_height) {
  constexpr std::array texts{"M", "g", "@"};
  constexpr std::array styles{GlyphStyle::regular, GlyphStyle::bold, GlyphStyle::italic, GlyphStyle::bold_italic};
  std::size_t comparisons = 0;
  original.select(static_cast<std::uint32_t>(pixel_height * scale));
  for (const auto style : styles) {
    for (const auto *const text : texts) {
      optical.begin({image_extent / scale, image_extent / scale}, scale, strength);
      QTextLayout layout;
      shapeGlyph(layout, QString::fromLatin1(text), pixel_height, style);
      compareGlyph(optical, original, layout, scale, style);
      ++comparisons;
    }
  }

  return comparisons;
}

void verifyRasters() {
  telar::gui::qt::bundledFonts();
  QFile font{QStringLiteral(":/telar/fonts/JetBrainsMono-Regular.ttf")};
  require(font.open(QIODeviceBase::ReadOnly), "Bundled optical oracle font is missing");
  const auto bytes = font.readAll();
  const auto optical = telar::gui::qt::OpticalText::create();
  require(optical != nullptr, "macOS optical text is unavailable");
  constexpr std::array<std::uint8_t, 3> strengths{0, 128, opaque_channel};
  constexpr std::array pixel_heights{8, 12, 15, 32, 60, 96};
  constexpr std::array scales{1, 2};
  std::size_t comparisons = 0;
  for (const auto strength : strengths) {
    OriginalRasterizer original{bytes, strength};
    for (const auto scale : scales) {
      for (const auto pixel_height : pixel_heights) {
        comparisons += compareSize(*optical, original, strength, scale, pixel_height);
      }
    }
  }

  std::cout << "Matched " << comparisons << " CoreText glyph rasters byte-for-byte against the original native renderer\n";
}

}

int main(int argc, char **argv) {
  try {
    const QGuiApplication application{argc, argv};
    verifyRasters();
    verifySnapshotAndCompositing();
    verifyInvalidDimensions();
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
