#pragma once

#include "core/configuration.hpp"
#include "core/memory.hpp"
#include "font_source.hpp"
#include "fonts/face.hpp"
#include "terminal/font_grid.hpp"
#include "ui/workbench/terminal_font.hpp"
#include <QtCore/qtypes.h>

namespace telar::gui::qt {

struct ResolvedFont {
  workbench::TerminalFont font;
  FontGrid grid;
};

class FontResolver {
public:
  template <Allocator Memory>
  [[nodiscard]] static ResolvedFont resolve(Memory &memory, const FontConfiguration &configuration, qreal scale) {
    static_cast<void>(FontGrid::pixelHeight(configuration, static_cast<float>(scale)));
    const FontSource<Memory> source{memory, configuration};
    fonts::Face face{source.bytes(), source.match()};
    return resolve(face, configuration, scale);
  }

  [[nodiscard]] static ResolvedFont resolve(fonts::Face &face, const FontConfiguration &configuration, qreal scale);

private:
  static ResolvedFont compose(const fonts::Face &face, FontGrid grid, qreal scale);
};

}
