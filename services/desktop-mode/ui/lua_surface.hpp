#pragma once

#include "file_watch.hpp"
#include "quick_surface.hpp"
#include "surface_kind.hpp"
#include <QSize>
#include <QTimer>
#include <memory>

namespace ui {
  struct Services;
  class LuaUi;
} // namespace ui

struct LuaSurface final : QuickSurface {
  LuaSurface(ui::Services &services, const QSize &size, ui::SurfaceKind kind);
  ~LuaSurface();

private:
  ui::SurfaceKind kind_;
  QString config_path_;
  bool config_required_ = false;
  std::unique_ptr<ui::LuaUi> ui_;
  ui::FileWatch watcher_;
  QTimer reload_timer_;

  void reload();
  void watchScript();
  void rearmWatcher();
};
