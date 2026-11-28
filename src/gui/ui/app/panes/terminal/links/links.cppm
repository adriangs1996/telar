export module telar.gui.ui.app.panes.terminal.links;

import std;
import telar.gui.qt;
import telar.gui.foundation.core;
import telar.gui.application;
import telar.base.ds;
import telar.wire.vocabulary;

export namespace telar::gui::qt {

  struct LinkPreview {
    static constexpr qreal maximum_width = 640;
    static constexpr int maximum_rows = 12;
    static constexpr qreal margin = 8;
    static constexpr qreal padding = 10;
    static constexpr qreal radius = 7;

    QRectF bounds;
    QStringList lines;
    QFont font;
    qreal inset = 0;
    qreal row_height = 0;
    qreal corner_radius = 0;

    [[nodiscard]] static ds::Option<LinkPreview> layout(const application::terminal::links::LinkHit& hit, const TerminalSurface& surface, const QFont& font, qreal chrome_scale);
  };

}
