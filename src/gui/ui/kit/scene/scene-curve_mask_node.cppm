export module telar.gui.ui.kit.scene:curve_mask_node;

import std;
import telar.gui.qt;
import :curve_mask;
import telar.gui.foundation.core;
import telar.wire.vocabulary;

export namespace telar::gui::qt {

  void appendCurveMask(QSGNode& parent, CurveMaskRef mask, const QRectF& bounds, Color foreground);

}
