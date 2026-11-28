export module telar.gui.ui.app.panes.header:pane_chrome_style;

import telar.gui.qt;
import telar.gui.foundation.drawing;
import telar.gui.application;

export namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  [[tbc::hot_path]] inline QVariantMap paneChromeStyle(qreal ratio, qreal density) {
    return {
        {u"chipInset"_s, static_cast<qreal>(application::workbench::PaneStatusChip::inset) * ratio},
        {u"chipHeight"_s, static_cast<qreal>(application::workbench::PaneStatusChip::height) * ratio},
        {u"chipRadius"_s, static_cast<qreal>(application::workbench::PaneStatusChip::radius) * ratio},
        {u"progressPadding"_s, static_cast<qreal>(ProgressGeometry::padding) * ratio},
        {u"progressSide"_s, static_cast<qreal>(ProgressGeometry::ring_side) * ratio},
        {u"progressHeight"_s, static_cast<qreal>(ProgressGeometry::height) * ratio},
        {u"progressInset"_s, static_cast<qreal>(ProgressGeometry::ring_inset) * ratio},
        {u"density"_s, density},
    };
  }

}
