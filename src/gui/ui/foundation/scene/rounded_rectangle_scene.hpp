#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "tbc/view.hpp"
#include <QQuickWindow>
#include <QSGNode>
#include <QtCore/qtypes.h>
#include <span>

#pragma once

import telar.gui.foundation.drawing;

namespace telar::gui::qt {

  // Each result reuses the previous node or is a new one the caller adopts.
  tbc::val_a<QSGNode*> paintRoundedRectangleAt(QQuickWindow& window, tbc::val_a<QSGNode*> previous, RoundedRectanglePaint paint, qreal density);
  tbc::val_a<QSGNode*> paintSoftwareRoundedRectangleAt(QQuickWindow& window, tbc::val_a<QSGNode*> previous, RoundedRectanglePaint paint, qreal density);
  void paintRoundedRectangles(QQuickWindow& window, QSGNode& root, std::span<const RoundedRectanglePaint> paints, qreal density);

}
