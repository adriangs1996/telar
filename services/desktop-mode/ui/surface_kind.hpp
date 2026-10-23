#pragma once

namespace ui {
  enum class SurfaceKind {
    topbar,
    sidebar,
    wallpaper,
    workbench,
    // The backstage switcher, shown over a display while the user picks a window.
    backstage
  };
} // namespace ui
