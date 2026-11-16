#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "cell_text_grid.hpp"
#include "platform/font.h"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "ui/fonts/resident_fonts.hpp"
#include <QString>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <concepts>
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
#include <utility>

#pragma once

import telar.gui.fonts.face;

namespace telar::gui::qt {

  struct FormTextGrid {
    [[nodiscard]] static CellTextGrid resolve(const QString& family, const QString& style, std::uint16_t pixels) {
      const auto source = ResidentFonts::resolveSource(family, style);
      const auto resident = ResidentFonts::shared(source);
      const auto metrics = resident->face(fonts::FontRole::primary).metrics(pixels);

      return {
          .metrics = {.width = metrics.maximum_advance, .height = static_cast<std::uint16_t>(std::min(metrics.line_height, static_cast<std::uint32_t>(std::numeric_limits<std::uint16_t>::max()))), .pixel_height = pixels, .baseline = static_cast<float>(metrics.ascender)},
          .family = family,
          .style = style,
      };
    }
  };

}
