#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <QVariantMap>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtypes.h>

#pragma once

import telar.gui.foundation.drawing;
import telar.gui.application;

namespace telar::gui::qt {

  inline QVariantMap paneChromeStyle(qreal ratio, qreal density) {
    return {
        {QStringLiteral("chipInset"), static_cast<qreal>(application::workbench::PaneStatusChip::inset) * ratio},
        {QStringLiteral("chipHeight"), static_cast<qreal>(application::workbench::PaneStatusChip::height) * ratio},
        {QStringLiteral("chipRadius"), static_cast<qreal>(application::workbench::PaneStatusChip::radius) * ratio},
        {QStringLiteral("progressPadding"), static_cast<qreal>(ProgressGeometry::padding) * ratio},
        {QStringLiteral("progressSide"), static_cast<qreal>(ProgressGeometry::ring_side) * ratio},
        {QStringLiteral("progressHeight"), static_cast<qreal>(ProgressGeometry::height) * ratio},
        {QStringLiteral("progressInset"), static_cast<qreal>(ProgressGeometry::ring_inset) * ratio},
        {QStringLiteral("density"), density},
    };
  }

}
