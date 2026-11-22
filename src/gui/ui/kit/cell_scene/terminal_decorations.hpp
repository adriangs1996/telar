#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_wire/serializers/telar_cells.hpp"
#include "ui/kit/models/projection.hpp"
#include "ui/kit/scene/rounded_rectangle_scene.hpp"
#include "ui/kit/scene/scene_nodes.hpp"
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QSGSimpleRectNode>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string_view>

#pragma once

import telar.gui.foundation.core;
import telar.gui.foundation.drawing;

namespace telar::gui::qt {

  class TerminalDecorations {
  public:
    static void rectangle(QQuickWindow& window, QSGNode& parent, const QRectF& bounds, Color foreground, qreal scale) {
      if (std::equal_to<>{}(foreground.a, 1)) {
        appendSceneNode<QSGSimpleRectNode>(parent, bounds, toQColor(foreground));
        return;
      }

      const RoundedRectanglePaint paint{.origin = {.x = static_cast<float>(bounds.x() * scale), .y = static_cast<float>(bounds.y() * scale)}, .shape = {.size = {.x = static_cast<float>(bounds.width() * scale), .y = static_cast<float>(bounds.height() * scale)}, .style = {.fill = foreground}}};

      adoptSceneNode(parent, std::unique_ptr<QSGNode>{paintRoundedRectangleAt(window, nullptr, paint, scale)});
    }
  };

}
