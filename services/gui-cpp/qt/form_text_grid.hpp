#pragma once

#include "cell_text_grid.hpp"
#include "fonts/face.hpp"
#include "fonts/font_role.hpp"
#include "resident_fonts.hpp"
#include <QString>
#include <algorithm>
#include <cstdint>
#include <limits>

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
