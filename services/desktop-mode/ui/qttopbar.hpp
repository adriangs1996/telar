#pragma once

#include "file_watch.hpp"
#include "quick_surface.hpp"
#include <QSize>
#include <QTimer>
#include <memory>

namespace ui {
  struct Services;
  class LuaUi;
} // namespace ui

struct QtTopBarSurface final : QuickSurface {
  QtTopBarSurface(ui::Services &services, const QSize &size);
  ~QtTopBarSurface();

private:
  QString script_path_;
  std::unique_ptr<ui::LuaUi> ui_;
  ui::FileWatch watcher_;
  QTimer reload_timer_;

  void reload();
  void watchScript();
  void rearmWatcher();
};
