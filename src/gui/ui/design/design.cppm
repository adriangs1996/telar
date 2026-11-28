export module telar.gui.ui.design;

import telar.gui.qt;
import telar.gui.foundation.core;
import telar.gui.foundation.drawing;

export namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  [[tbc::hot_path]] inline QVariantMap historyHintRecord(const HistoryHintGeometry& geometry, qreal density) {
    const auto local = [&](Rect area) {
      return QRectF{static_cast<qreal>(area.x - geometry.bounds.x) / density, static_cast<qreal>(area.y - geometry.bounds.y) / density, static_cast<qreal>(area.width) / density, static_cast<qreal>(area.height) / density};
    };

    const auto bounds = geometry.bounds;

    return {
        {u"bounds"_s, QRectF{static_cast<qreal>(bounds.x) / density, static_cast<qreal>(bounds.y) / density, static_cast<qreal>(bounds.width) / density, static_cast<qreal>(bounds.height) / density}},
        {u"keycap"_s, local(geometry.keycap)},
        {u"keyText"_s, local(geometry.key_text)},
        {u"word"_s, local(geometry.word)},
    };
  }

  [[tbc::hot_path]] inline QVariantMap historyHintStyle(qreal ratio) {
    return {
        {u"radius"_s, static_cast<qreal>(HistoryHintGeometry::corner_radius) * ratio},
        {u"ringWidth"_s, static_cast<qreal>(HistoryHintGeometry::ring_width) * ratio},
        {u"keyRingAlpha"_s, HistoryHintGeometry::key_ring_alpha},
        {u"keyTextAlpha"_s, HistoryHintGeometry::key_text_alpha},
    };
  }

}
