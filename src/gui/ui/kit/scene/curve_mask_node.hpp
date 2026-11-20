#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "curve_mask.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include <QRectF>
#include <QSGNode>
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>

#pragma once

import telar.gui.foundation.core;

namespace telar::gui::qt {

  void appendCurveMask(QSGNode& parent, CurveMaskRef mask, const QRectF& bounds, Color foreground);

}
