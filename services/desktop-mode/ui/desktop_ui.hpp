#pragma once

#include "lua_ui.hpp"
#include "module_watch.hpp"
#include "surface_kind.hpp"
#include <QQmlEngine>
#include <QTimer>
#include <QRectF>
#include <cstdint>
#include <map>
#include <set>

struct LuaSurface;

namespace ui {
  class DesktopUi final {
  public:
    explicit DesktopUi(Services &services);
    ~DesktopUi();

    Services &services() noexcept;
    QQmlEngine &engine() noexcept;
    void attach(LuaSurface &surface, SurfaceKind kind);
    void detach(LuaSurface &surface);
    QVariantMap options(SurfaceKind kind) const;
    QRectF workArea(std::uint32_t display, QRectF available) const;
    std::function<void()> changed;

  private:
    Services &services_;
    // Shared by every surface, which must not outlive it.
    QQmlEngine engine_;
    // Shared by every Lua environment, which must not outlive it.
    ModuleWatch modules_;
    LuaUi configuration_;
    QString config_path_;
    bool config_required_ = false;
    QVariantMap settings_;
    QString prefix_;
    std::map<LuaSurface *, SurfaceKind> surfaces_;
    std::uint64_t config_watch_ = 0;
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
