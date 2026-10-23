#pragma once

#include <QColor>
#include <QPointF>
#include <QSizeF>
#include <cstdint>
#include <memory>

class QQuickWindow;
class QSGNode;
class QTextLayout;

namespace workbench {
  // Draws a terminal row's text with the platform's font smoothing at a chosen strength, as the
  // GUI's `thicken` does, into one texture per row. It lives with the scene graph on its render
  // thread. Where the platform has no such smoothing, create() returns nothing and rows draw with
  // Qt's native text instead.
  class OpticalText {
  public:
    static std::unique_ptr<OpticalText> create();
    virtual ~OpticalText() = default;

    // Starts a row: a clear buffer of `size` logical pixels at `scale`.
    virtual void begin(QSizeF size, qreal scale, std::uint8_t strength) = 0;
    virtual void add(const QTextLayout &layout, QPointF position, QColor color) = 0;
    // The row's ink as a texture node placed at `position`, or nullptr when nothing was drawn.
    virtual QSGNode *node(QQuickWindow &window, QPointF position) = 0;
  };
} // namespace workbench
