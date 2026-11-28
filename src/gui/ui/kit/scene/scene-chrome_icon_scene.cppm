export module telar.gui.ui.kit.scene:chrome_icon_scene;

import std;
import telar.gui.qt;
import telar.tbc;
import telar.gui.ui.kit.fonts;
import telar.gui.foundation.core;
import telar.gui.foundation.fonts;

export namespace telar::gui::qt {

  struct ChromeIconPaint {
    std::span<const fonts::IconGlyph> glyphs;
    Rect ink;
    std::shared_ptr<const FontAsset> source;
    QPointF scene_origin;
    QSizeF bounds;
    QColor color;
    qreal scale = 1;
    float target_side = 0;
    std::uint16_t pixel_height = 0;
    std::uint64_t revision = 0;
  };

  // The result reuses the previous node or is a new one the caller adopts.
  tbc::val_a<QSGNode*> paintChromeIcon(tbc::val_a<QSGNode*> previous, QQuickWindow& window, const ChromeIconPaint& paint);

}
