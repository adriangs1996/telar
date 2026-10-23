#pragma once

class QQuickImageProvider;

namespace ui {
  // Running applications' icons for QML, at image://app-icon/<pid>. The engine it is added to
  // owns it.
  QQuickImageProvider *appIcons();
} // namespace ui
