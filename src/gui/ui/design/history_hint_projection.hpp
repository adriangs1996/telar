#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <QRectF>
#include <QVariantMap>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtypes.h>

#pragma once

import telar.gui.foundation.core;
import telar.gui.foundation.drawing;

namespace telar::gui::qt {

  inline QVariantMap historyHintRecord(const HistoryHintGeometry& geometry, qreal density) {
    const auto local = [&](Rect area) {
      return QRectF{static_cast<qreal>(area.x - geometry.bounds.x) / density, static_cast<qreal>(area.y - geometry.bounds.y) / density, static_cast<qreal>(area.width) / density, static_cast<qreal>(area.height) / density};
    };

    const auto bounds = geometry.bounds;

    return {
        {QStringLiteral("bounds"), QRectF{static_cast<qreal>(bounds.x) / density, static_cast<qreal>(bounds.y) / density, static_cast<qreal>(bounds.width) / density, static_cast<qreal>(bounds.height) / density}},
        {QStringLiteral("keycap"), local(geometry.keycap)},
        {QStringLiteral("keyText"), local(geometry.key_text)},
        {QStringLiteral("word"), local(geometry.word)},
    };
  }

  inline QVariantMap historyHintStyle(qreal ratio) {
    return {
        {QStringLiteral("radius"), static_cast<qreal>(HistoryHintGeometry::corner_radius) * ratio},
        {QStringLiteral("ringWidth"), static_cast<qreal>(HistoryHintGeometry::ring_width) * ratio},
        {QStringLiteral("keyRingAlpha"), HistoryHintGeometry::key_ring_alpha},
        {QStringLiteral("keyTextAlpha"), HistoryHintGeometry::key_text_alpha},
    };
  }

}
