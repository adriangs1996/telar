#pragma once

#include "quick_surface.hpp"
#include "lua_ui.hpp"
#include "surface_kind.hpp"
#include <QSize>

namespace ui {
  class DesktopUi;
} // namespace ui

struct LuaSurface final : QuickSurface {
  LuaSurface(ui::DesktopUi &desktop, const QSize &size, ui::SurfaceKind kind);
  ~LuaSurface();

private:
  friend class ui::DesktopUi;
  ui::DesktopUi &desktop_;
  ui::SurfaceKind kind_;
  ui::LuaUi ui_;
};
