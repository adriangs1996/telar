#include "lua_surface.hpp"
#include "desktop_ui.hpp"

LuaSurface::LuaSurface(ui::DesktopUi &desktop,
                       const QSize &size,
                       ui::SurfaceKind kind,
                       QVariantMap configuration)
    : desktop_(desktop),
      ui_(desktop.services(), this),
      configuration_(std::move(configuration)) {
  window_.resize(size);
  desktop_.attach(*this, kind);
}

LuaSurface::~LuaSurface() {
  desktop_.detach(*this);
}
