#pragma once

#include "terminal/font_grid.hpp"
#include <QString>
#include <QVariantMap>
#include <QtCore/qtypes.h>
#include <QtCore/qvariant.h>
#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>

namespace telar::gui::qt {

struct CellTextGrid {
  FontGrid metrics;
  QString family;
  QString style;

  [[nodiscard]] QVariantMap record(qreal scale) const {
    return {
        {QStringLiteral("family"), family},
        {QStringLiteral("style"), style},
        {QStringLiteral("pixelHeight"), metrics.pixel_height / scale},
        {QStringLiteral("cellWidth"), metrics.width / scale},
        {QStringLiteral("cellHeight"), metrics.height / scale},
        {QStringLiteral("baseline"), metrics.baseline / scale},
    };
  }

  [[nodiscard]] static CellTextGrid resolve(const QVariantMap &value, qreal scale) {
    CellTextGrid result;
    result.metrics.width = dimension(value, "cellWidth", scale);
    result.metrics.height = dimension(value, "cellHeight", scale);
    result.metrics.pixel_height = dimension(value, "pixelHeight", scale);
    result.metrics.baseline = static_cast<float>(value.value(QStringLiteral("baseline")).toDouble() * scale);
    if (!std::isfinite(result.metrics.baseline)) {
      throw std::invalid_argument{"InvalidCellTextBaseline"};
    }

    result.family = value.value(QStringLiteral("family")).toString();
    result.style = value.value(QStringLiteral("style")).toString();

    return result;
  }

private:
  [[nodiscard]] static std::uint16_t dimension(const QVariantMap &value, const char *name, qreal scale) {
    const auto physical = std::round(static_cast<float>(value.value(QString::fromLatin1(name)).toDouble() * scale));
    if (!std::isfinite(physical) || physical < 1 || physical > std::numeric_limits<std::uint16_t>::max()) {
      throw std::invalid_argument{"InvalidCellTextGrid"};
    }

    return static_cast<std::uint16_t>(physical);
  }
};

}
