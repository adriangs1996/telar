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
#include "curve_mask.hpp"
#include <QRectF>
#include <QSGNode>

#pragma once


import telar.gui.core.metrics;

namespace telar::gui::qt {

void appendCurveMask(QSGNode &parent, CurveMaskRef mask, const QRectF &bounds, Color foreground);

}
