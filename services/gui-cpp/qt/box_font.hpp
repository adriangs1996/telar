#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include <QByteArray>
#include <QFont>
#include <QFontInfo>
#include <QRawFont>
#include <QtCore/qendian.h>
#include <QtCore/qtypes.h>
#include <limits>
#include <stdexcept>

#pragma once


import telar.gui.terminal.copy_mode;

namespace telar::gui::qt {

class BoxFont {
public:
  [[nodiscard]] static float thickness(const QFont &regular, qreal scale) {
    auto raw = QRawFont::fromFont(regular);
    const auto logical_height = raw.isValid() ? raw.pixelSize() : static_cast<qreal>(QFontInfo{regular}.pixelSize());
    const auto pixel_height = std::round(logical_height * scale);
    constexpr auto maximum_height = std::numeric_limits<std::uint16_t>::max();
    if (!std::isfinite(pixel_height) || pixel_height <= 0 || pixel_height > maximum_height) {
      throw std::invalid_argument{"InvalidPixelHeight"};
    }

    const auto height = static_cast<std::uint16_t>(pixel_height);
    if (!raw.isValid()) {
      return glyphs::BoxStroke{}.pixels(height);
    }

    if (!raw.fontTable("MVAR").isEmpty()) {
      raw.setPixelSize(pixel_height);
      const auto thickness = raw.lineThickness();

      return thickness > 0 ? static_cast<float>(std::max(1.0, std::ceil(thickness))) : glyphs::BoxStroke{}.pixels(height);
    }

    const auto head = raw.fontTable("head");
    const auto post = raw.fontTable("post");
    constexpr qsizetype units_per_em_offset = 18;
    constexpr qsizetype underline_thickness_offset = 10;
    glyphs::BoxStroke stroke;
    if (head.size() >= units_per_em_offset + static_cast<qsizetype>(sizeof(stroke.units_per_em))) {
      stroke.units_per_em = qFromBigEndian<std::uint16_t>(head.constData() + units_per_em_offset);
    }

    if (post.size() >= underline_thickness_offset + static_cast<qsizetype>(sizeof(stroke.underline_thickness))) {
      stroke.underline_thickness = qFromBigEndian<std::int16_t>(post.constData() + underline_thickness_offset);
    }

    return stroke.pixels(height);
  }
};

}
