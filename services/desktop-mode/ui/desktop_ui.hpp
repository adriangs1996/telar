#pragma once

#include "file_watch.hpp"
#include "lua_ui.hpp"
#include "surface_kind.hpp"
#include <QTimer>
#include <map>
#include <set>

struct LuaSurface;

namespace ui {
  class DesktopUi final {
  public:
    explicit DesktopUi(Services &services);

    Services &services() noexcept;
    void attach(LuaSurface &surface, SurfaceKind kind);
    void detach(LuaSurface &surface);

  private:
    Services &services_;
    LuaUi configuration_;
    QString config_path_;
    bool config_required_ = false;
    QVariantMap settings_;
    QString prefix_;
    std::map<LuaSurface *, SurfaceKind> surfaces_;
    FileWatch watcher_;
    QTimer reload_timer_;
    std::set<SurfaceKind> dirty_surfaces_;
    bool configuration_dirty_ = false;
    bool retry_configuration_ = false;

    void reloadConfiguration();
    void reloadPending();
    void prepareSurface(LuaSurface &surface,
                        SurfaceKind kind,
                        const QVariantMap &settings,
                        const QString &prefix);
  };
} // namespace ui
