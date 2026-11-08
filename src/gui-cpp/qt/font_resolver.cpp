#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "font_resolver.hpp"
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
#include <span>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include "../platform/font.h"
#include <cstring>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <type_traits>
#include "projection.hpp"
#include "bundled_fonts.hpp"
#include "terminal_font.hpp"
#include <QFont>
#include <QGuiApplication>
#include <QScreen>
#include <QString>
#include <QStringList>
#include <QtCore/qtypes.h>
#include <utility>



import telar.gui.core.metrics;
import telar.gui.fonts.face;
import telar.gui.terminal.font_grid;

namespace telar::gui::qt {

ResolvedFont FontResolver::resolve(fonts::Face &face, const FontConfiguration &configuration, qreal scale) {
  const auto ratio = static_cast<float>(scale);
  const auto height = FontGrid::pixelHeight(configuration, ratio);
  const auto grid = FontGrid::resolve(face.metrics(height), configuration, ratio);

  return compose(face, grid, scale);
}

ResolvedFont FontResolver::compose(const fonts::Face &face, FontGrid grid, qreal scale) {
  auto families = bundledFonts();
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

  auto font = TerminalFont::fromFont(std::move(base), {grid.width / scale, grid.height / scale}, grid.baseline / scale);
  font.fixed_pitch = face.fixedPitch();

  return {.font = std::move(font), .grid = grid};
}

}
