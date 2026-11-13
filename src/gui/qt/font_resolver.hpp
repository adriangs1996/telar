#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "../core/memory.hpp"
#include "../platform/font.h"
#include "font_source.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "terminal_font.hpp"
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <freetype/freetype.h>
#include <hb.h>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <type_traits>

#pragma once
#include "core/memory.hpp"

import telar.gui.core.metrics;
import telar.gui.fonts.face;
import telar.gui.terminal.font_grid;

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
