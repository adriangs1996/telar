#pragma once

#include <QPointF>
#include <cstdint>

class QWindow;

namespace window_hide_probe {
  // Lets mouse events pass through the window to whatever lies below it.
  void setIgnoresMouse(QWindow &window, bool ignores);
  std::uint32_t windowNumber(QWindow &window);
  // The window that a mouse down at the global point would hit.
  std::uint32_t windowAt(QPointF point);
  // The process memory footprint, as Activity Monitor reports it.
  std::uint64_t footprint();
} // namespace window_hide_probe
