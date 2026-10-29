#pragma once

#include "core/color.hpp"
#include "curve_mask.hpp"
#include <QRectF>
#include <QSGNode>

namespace telar::gui::qt {

void appendCurveMask(QSGNode &parent, CurveMaskRef mask, const QRectF &bounds, Color foreground);

}
