export module telar.gui.ui.kit.cell_scene:terminal_decorations;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.models;
import telar.gui.ui.kit.scene;
import telar.gui.foundation.core;
import telar.gui.foundation.drawing;
import telar.wire.vocabulary;

export namespace telar::gui::qt {

  class TerminalDecorations {
  public:
    [[tbc::hot_path]] inline static void rectangle(QQuickWindow& window, QSGNode& parent, const QRectF& bounds, Color foreground, qreal scale) {
      if (std::equal_to<>{}(foreground.a, 1)) {
        appendSceneNode<QSGSimpleRectNode>(parent, bounds, toQColor(foreground));
        return;
      }

      const RoundedRectanglePaint paint{.origin = {.x = static_cast<float>(bounds.x() * scale), .y = static_cast<float>(bounds.y() * scale)}, .shape = {.size = {.x = static_cast<float>(bounds.width() * scale), .y = static_cast<float>(bounds.height() * scale)}, .style = {.fill = foreground}}};

      adoptSceneNode(parent, std::unique_ptr<QSGNode>{paintRoundedRectangleAt(window, nullptr, paint, scale)});
    }
  };

}
