#include "quick_surface.hpp"
#include <QFileSystemWatcher>
#include <QTimer>

struct QtTopBarSurface final : QuickSurface {
  explicit QtTopBarSurface(lua::Vm &lua_vm);

private:
  QString script_path_;
  QQuickItem *text_item_ = nullptr;
  QFileSystemWatcher watcher_;
  QTimer reload_timer_;

  void reload();
  void watchScript();
};
