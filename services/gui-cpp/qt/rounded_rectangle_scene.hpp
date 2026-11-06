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
#include <cmath>
#include <QQuickWindow>
#include <QSGNode>
#include <QtCore/qtypes.h>
#include <span>

#pragma once


import telar.gui.graphics.placeholder;

namespace telar::gui::qt {

QSGNode *paintRoundedRectangle(QQuickWindow &window, QSGNode *previous, RoundedRectangle shape, qreal density);
QSGNode *paintRoundedRectangleAt(QQuickWindow &window, QSGNode *previous, RoundedRectanglePaint paint, qreal density);
QSGNode *paintSoftwareRoundedRectangle(QQuickWindow &window, QSGNode *previous, RoundedRectangle shape, qreal density);
QSGNode *paintSoftwareRoundedRectangleAt(QQuickWindow &window, QSGNode *previous, RoundedRectanglePaint paint, qreal density);
void paintRoundedRectangles(QQuickWindow &window, QSGNode &root, std::span<const RoundedRectanglePaint> paints, qreal density);

}
