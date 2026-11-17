#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <QVariantMap>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtypes.h>

#pragma once

import telar.gui.presentation.activity_order;
import telar.gui.foundation.drawing;

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
