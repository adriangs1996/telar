#pragma once

class QQuickImageProvider;

namespace ui {
  // Bounded asynchronous artwork loading at image://artwork/{provider,favicon,glyph}/...
  QQuickImageProvider *artwork();
} // namespace ui
