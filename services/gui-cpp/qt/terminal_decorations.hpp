#pragma once

#include "core/color.hpp"
#include "graphics/rounded_rectangle.hpp"
#include "projection.hpp"
#include "rounded_rectangle_scene.hpp"
#include "scene_nodes.hpp"
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QSGSimpleRectNode>
#include <QtCore/qtypes.h>
#include <memory>

namespace telar::gui::qt {

class TerminalDecorations {
public:
  static void rectangle(QQuickWindow &window, QSGNode &parent, const QRectF &bounds, Color foreground, qreal scale) {
    if (foreground.a == 1) {
      appendSceneNode<QSGSimpleRectNode>(parent, bounds, toQColor(foreground));
      return;
    }

    const RoundedRectanglePaint paint{.origin = {.x = static_cast<float>(bounds.x() * scale), .y = static_cast<float>(bounds.y() * scale)}, .shape = {.size = {.x = static_cast<float>(bounds.width() * scale), .y = static_cast<float>(bounds.height() * scale)}, .style = {.fill = foreground}}};
    adoptSceneNode(parent, std::unique_ptr<QSGNode>{paintRoundedRectangleAt(window, nullptr, paint, scale)});
  }
};

}
