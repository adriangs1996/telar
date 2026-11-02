#pragma once

#include "core/geometry.hpp"
#include "presentation/history_hint_geometry.hpp"
#include <QRectF>
#include <QVariantMap>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtypes.h>

namespace telar::gui::qt {

inline QVariantMap historyHintRecord(const HistoryHintGeometry &geometry, qreal density) {
  const auto local = [&](Rect area) {
    return QRectF{(area.x - geometry.bounds.x) / density, (area.y - geometry.bounds.y) / density, area.width / density, area.height / density};
  };
  const auto bounds = geometry.bounds;

  return {
      {QStringLiteral("bounds"), QRectF{bounds.x / density, bounds.y / density, bounds.width / density, bounds.height / density}},
      {QStringLiteral("keycap"), local(geometry.keycap)},
      {QStringLiteral("keyText"), local(geometry.key_text)},
      {QStringLiteral("word"), local(geometry.word)},
  };
}

inline QVariantMap historyHintStyle(qreal ratio) {
  return {
      {QStringLiteral("radius"), HistoryHintGeometry::corner_radius * ratio},
      {QStringLiteral("ringWidth"), HistoryHintGeometry::ring_width * ratio},
      {QStringLiteral("keyRingAlpha"), HistoryHintGeometry::key_ring_alpha},
      {QStringLiteral("keyTextAlpha"), HistoryHintGeometry::key_text_alpha},
  };
}

}
