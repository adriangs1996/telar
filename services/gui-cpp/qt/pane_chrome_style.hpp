#pragma once

#include "presentation/pane_chrome.hpp"
#include "presentation/progress_geometry.hpp"
#include <QVariantMap>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtypes.h>

namespace telar::gui::qt {

inline QVariantMap paneChromeStyle(qreal ratio, qreal density) {
  return {
      {QStringLiteral("chipInset"), PaneStatusChip::inset * ratio},
      {QStringLiteral("chipHeight"), PaneStatusChip::height * ratio},
      {QStringLiteral("chipRadius"), PaneStatusChip::radius * ratio},
      {QStringLiteral("progressPadding"), ProgressGeometry::padding * ratio},
      {QStringLiteral("progressSide"), ProgressGeometry::ring_side * ratio},
      {QStringLiteral("progressHeight"), ProgressGeometry::height * ratio},
      {QStringLiteral("progressInset"), ProgressGeometry::ring_inset * ratio},
      {QStringLiteral("density"), density},
  };
}

}
