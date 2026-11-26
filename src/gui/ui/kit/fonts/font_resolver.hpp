#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "font_source.hpp"
#include "terminal_font.hpp"
#include <QtCore/qtypes.h>

#pragma once

import telar.gui.foundation.core;
import telar.gui.foundation.fonts;
import telar.gui.foundation.terminal;

namespace telar::gui::qt {

  struct ResolvedFont {
    TerminalFont font;
    FontGrid grid;
  };

  class FontResolver {
  public:
    template <Allocator Memory>
    [[nodiscard]] static ResolvedFont resolve(Memory& memory, const FontConfiguration& configuration, qreal scale) {
      static_cast<void>(FontGrid::pixelHeight(configuration, static_cast<float>(scale)));
      const FontSource<Memory> source{memory, configuration};
      fonts::Face face{source.bytes(), source.match()};

      return resolve(face, configuration, scale);
    }

    [[nodiscard]] static ResolvedFont resolve(fonts::Face& face, const FontConfiguration& configuration, qreal scale);

  private:
    static ResolvedFont compose(const fonts::Face& face, FontGrid grid, qreal scale);
  };

}
