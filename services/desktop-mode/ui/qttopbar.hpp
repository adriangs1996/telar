#pragma once

#include "file_watch.hpp"
#include "quick_surface.hpp"
#include <QSize>
#include <QTimer>
#include <memory>

namespace lua {
  struct Vm;
}

namespace ui {
  class LuaUi;
}

struct QtTopBarSurface final : QuickSurface {
  QtTopBarSurface(lua::Vm &lua_vm, const QSize &size);
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
