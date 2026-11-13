#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "cell_text_grid.hpp"
#include <cstddef>
#include <cstdint>
#include <span>
#include <array>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include <string_view>
#include "../platform/font.h"
#include <algorithm>
#include <cstring>
#include "telar_client/serializers/telar_cells.hpp"
#include <optional>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <type_traits>
#include <concepts>
#include <utility>
#include "resident_fonts.hpp"
#include <QString>

#pragma once



import telar.gui.fonts.face;

namespace telar::gui::qt {

struct FormTextGrid {
  [[nodiscard]] static CellTextGrid resolve(const QString &family, const QString &style, std::uint16_t pixels) {
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
