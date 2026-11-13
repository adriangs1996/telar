#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


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
#include "../core/memory.hpp"
#include "font_source.hpp"
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
#include "terminal_font.hpp"
#include <QtCore/qtypes.h>

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
