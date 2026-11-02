#pragma once

#include "graphics/rounded_rectangle.hpp"
#include <QQuickWindow>
#include <QSGNode>
#include <QtCore/qtypes.h>
#include <span>

namespace telar::gui::qt {

QSGNode *paintRoundedRectangle(QQuickWindow &window, QSGNode *previous, RoundedRectangle shape, qreal density);
QSGNode *paintRoundedRectangleAt(QQuickWindow &window, QSGNode *previous, RoundedRectanglePaint paint, qreal density);
QSGNode *paintSoftwareRoundedRectangle(QQuickWindow &window, QSGNode *previous, RoundedRectangle shape, qreal density);
QSGNode *paintSoftwareRoundedRectangleAt(QQuickWindow &window, QSGNode *previous, RoundedRectanglePaint paint, qreal density);
void paintRoundedRectangles(QQuickWindow &window, QSGNode &root, std::span<const RoundedRectanglePaint> paints, qreal density);

}
