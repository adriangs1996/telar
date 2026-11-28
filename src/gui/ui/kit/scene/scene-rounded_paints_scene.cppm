export module telar.gui.ui.kit.scene:rounded_paints_scene;

import std;
import telar.gui.qt;
import telar.tbc;
import :rounded_rectangle_scene;
import telar.gui.foundation.core;
import telar.gui.foundation.drawing;
import telar.base.ds;

export namespace telar::gui::qt {

  // The node painted is the previous one again or a new one Qt takes: region `a`.
  template <std::size_t Capacity, typename Draw>
  [[tbc::generic]] tbc::val_a<QSGNode*> paintRoundedShapes(QQuickItem& item, tbc::val_a<QSGNode*> previous, Draw draw) {
    auto& window = *item.window();
    const auto density = window.effectiveDevicePixelRatio();
    const auto anchor = item.mapToScene(QPointF{});
    const Rect area{.x = static_cast<float>(anchor.x() * density), .y = static_cast<float>(anchor.y() * density), .width = static_cast<float>(item.width() * density), .height = static_cast<float>(item.height() * density)};
    auto root = std::unique_ptr<QSGTransformNode>{dynamic_cast<QSGTransformNode*>(previous)};
    if (!root) {
      root = std::make_unique<QSGTransformNode>();
    }

    QMatrix4x4 transform;

    transform.translate(static_cast<float>(-anchor.x()), static_cast<float>(-anchor.y()));
    root->setMatrix(transform);
    ds::Array<RoundedRectanglePaint, Capacity> paints;
    std::size_t count = 0;
    const auto append = [&](RoundedRectanglePaint paint) {
      if (count == paints.size()) {
        telar::qt::fatal("Rounded paint capacity exceeded");
      }

      paints.atMut(count++) = paint;
    };

    draw(append, area);
    paintRoundedRectangles(window, *root, std::span{paints}.first(count), density);

    return root.release();
  }

}
