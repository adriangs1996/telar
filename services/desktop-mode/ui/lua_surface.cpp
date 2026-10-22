#include "lua_surface.hpp"
#include "desktop_ui.hpp"
#include "../trace.hpp"

LuaSurface::LuaSurface(ui::DesktopUi &desktop,
                       const QSize &size,
                       ui::SurfaceKind kind,
                       QVariantMap configuration)
    : QuickSurface(desktop.engine()),
      desktop_(desktop),
      ui_(desktop.services(), this),
      configuration_(std::move(configuration)) {
  TELAR_TRACE("ui.lua_surface.create");
  window_.resize(size);
  desktop_.attach(*this, kind);
}

LuaSurface::~LuaSurface() {
  desktop_.detach(*this);
}
