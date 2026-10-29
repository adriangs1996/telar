#include "font_resolver.hpp"
#include "core/configuration.hpp"
#include "fonts/face.hpp"
#include "projection.hpp"
#include "terminal/font_grid.hpp"
#include "ui/bundled_fonts.hpp"
#include "ui/workbench/terminal_font.hpp"
#include <QFont>
#include <QGuiApplication>
#include <QScreen>
#include <QString>
#include <QStringList>
#include <QtCore/qtypes.h>
#include <cstddef>
#include <stdexcept>
#include <utility>

namespace telar::gui::qt {

ResolvedFont FontResolver::resolve(fonts::Face &face, const FontConfiguration &configuration, qreal scale) {
  const auto ratio = static_cast<float>(scale);
  const auto height = FontGrid::pixelHeight(configuration, ratio);
  const auto grid = FontGrid::resolve(face.metrics(height), configuration, ratio);

  return compose(face, grid, scale);
}

ResolvedFont FontResolver::compose(const fonts::Face &face, FontGrid grid, qreal scale) {
  auto families = ui::bundledFonts();
  families.prepend(toQString(face.family()));
  QFont base;
  base.setFamilies(families);
  base.setStyleName(toQString(face.style()));
  constexpr qreal points_per_inch = 72;
  const auto *screen = QGuiApplication::primaryScreen();
  const auto dpi = screen != nullptr ? screen->logicalDotsPerInchY() : points_per_inch;
  base.setPointSizeF(grid.pixel_height / scale * points_per_inch / dpi);
  const auto variation = face.variation();
  for (std::size_t index = 0; index < variation.count; ++index) {
    const auto tag = QFont::Tag::fromValue(variation.tags[index]);
    if (!tag) {
      throw std::invalid_argument{"FontVariationAxisMissing"};
    }

    base.setVariableAxis(*tag, variation.values[index]);
  }

  auto font = workbench::TerminalFont::fromFont(std::move(base), {grid.width / scale, grid.height / scale}, grid.baseline / scale);
  font.fixed_pitch = face.fixedPitch();

  return {.font = std::move(font), .grid = grid};
}

}
