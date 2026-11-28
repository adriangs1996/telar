export module telar.gui.ui.kit.scene:rounded_rectangle_scene;

import std;
import telar.gui.qt;
import telar.tbc;
import telar.gui.foundation.drawing;

export namespace telar::gui::qt {

  // Each result reuses the previous node or is a new one the caller adopts.
  tbc::val_a<QSGNode*> paintRoundedRectangleAt(QQuickWindow& window, tbc::val_a<QSGNode*> previous, RoundedRectanglePaint paint, qreal density);
  tbc::val_a<QSGNode*> paintSoftwareRoundedRectangleAt(QQuickWindow& window, tbc::val_a<QSGNode*> previous, RoundedRectanglePaint paint, qreal density);
  void paintRoundedRectangles(QQuickWindow& window, QSGNode& root, std::span<const RoundedRectanglePaint> paints, qreal density);

}
