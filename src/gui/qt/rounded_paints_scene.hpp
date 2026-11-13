#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <string_view>
#include "rounded_rectangle_scene.hpp"
#include <QMatrix4x4>
#include <QPointF>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSGNode>
#include <QSGTransformNode>
#include <QtCore/qlogging.h>
#include <QtCore/qtypes.h>
#include <memory>
#include <span>
#include "tbc/view.hpp"

#pragma once


import telar.gui.core.metrics;
import telar.gui.graphics.placeholder;

namespace telar::gui::qt {

// The node painted is the previous one again or a new one Qt takes: region `a`.
template <std::size_t Capacity, typename Draw>
tbc::view<QSGNode *, tbc::lt::a> paintRoundedShapes(QQuickItem &item, tbc::view<QSGNode *, tbc::lt::a> previous, Draw draw) {
  auto &window = *item.window();
  const auto density = window.effectiveDevicePixelRatio();
  const auto anchor = item.mapToScene(QPointF{});
  const Rect area{.x = static_cast<float>(anchor.x() * density), .y = static_cast<float>(anchor.y() * density), .width = static_cast<float>(item.width() * density), .height = static_cast<float>(item.height() * density)};
  auto root = std::unique_ptr<QSGTransformNode>{dynamic_cast<QSGTransformNode *>(previous)};
  if (!root) {
    root = std::make_unique<QSGTransformNode>();
  }

  QMatrix4x4 transform;
  transform.translate(static_cast<float>(-anchor.x()), static_cast<float>(-anchor.y()));
  root->setMatrix(transform);
  std::array<RoundedRectanglePaint, Capacity> paints;
  std::size_t count = 0;
  const auto append = [&](RoundedRectanglePaint paint) {
    if (count == paints.size()) {
      qFatal("Rounded paint capacity exceeded");
    }

    paints[count++] = paint;
  };
  draw(append, area);
  paintRoundedRectangles(window, *root, std::span{paints}.first(count), density);

  return root.release();
}

}
