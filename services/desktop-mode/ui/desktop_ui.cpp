#include "desktop_ui.hpp"
#include "lua_script.hpp"
#include "lua_surface.hpp"
#include <QDebug>
#include <QDir>
#include <QFileInfo>
#include <array>
#include <chrono>
#include <stdexcept>
#include <utility>

namespace {
  constexpr auto refresh_delay = std::chrono::milliseconds{200};

  QString surfaceName(ui::SurfaceKind kind) {
    switch (kind) {
    case ui::SurfaceKind::topbar:
      return QStringLiteral("topbar");
    case ui::SurfaceKind::sidebar:
      return QStringLiteral("sidebar");
    case ui::SurfaceKind::wallpaper:
      return QStringLiteral("wallpaper");
    case ui::SurfaceKind::workbench:
      return QStringLiteral("workbench");
    }

    throw std::runtime_error("Unknown desktop surface");
  }
} // namespace

namespace ui {
  DesktopUi::DesktopUi(Services &services)
      : services_(services),
        configuration_(services) {
    config_path_ = qEnvironmentVariable("TELAR_DESKTOP_CONFIG");
    config_required_ = !config_path_.isEmpty();

    if (!config_required_) {
      auto directory = qEnvironmentVariable("XDG_CONFIG_HOME");

      if (directory.isEmpty()) {
        directory = QDir::home().filePath(QStringLiteral(".config"));
      }

      config_path_ = QDir(directory).filePath(QStringLiteral("telar/desktop.lua"));
    } else if (config_path_.startsWith(QStringLiteral("~/"))) {
      config_path_ = QDir::home().filePath(config_path_.mid(2));
    }

    config_path_ = QFileInfo(config_path_).absoluteFilePath();
    reload_timer_.setSingleShot(true);
    reload_timer_.setInterval(refresh_delay);

    configuration_.setReloadHandler([this] {
      configuration_dirty_ = true;
      reload_timer_.start();
    });

    watcher_.setCallback([this](const QStringList &) {
      configuration_dirty_ = true;
      reload_timer_.start();
    });

    QObject::connect(&reload_timer_, &QTimer::timeout, &reload_timer_, [this] {
      reloadPending();
    });

    watcher_.setPaths({config_path_});
    reloadConfiguration();
  }

  Services &DesktopUi::services() noexcept {
    return services_;
  }

  void DesktopUi::prepareSurface(LuaSurface &surface,
                                 SurfaceKind kind,
                                 const QVariantMap &settings,
                                 const QString &prefix) {
    const auto name = surfaceName(kind);
    auto config =
        settings
            .value(name, QVariantMap{{"name", name}, {"module", name}, {"options", QVariantMap{}}})
            .toMap();
    for (auto it = surface.configuration_.cbegin(); it != surface.configuration_.cend(); ++it) {
      config.insert(it.key(), it.value());
    }
    surface.ui_.prepare("require(require(\"telar.ui\").surface.module)",
                        "@telar/surface",
                        QFileInfo(config_path_).absolutePath(),
                        config,
                        prefix);
  }

  void DesktopUi::attach(LuaSurface &surface, SurfaceKind kind) {
    if (surfaces_.contains(&surface)) {
      throw std::runtime_error("Desktop surface is already attached");
    }

    prepareSurface(surface, kind, settings_, prefix_);

    surface.ui_.setReloadHandler([this, kind] {
      dirty_surfaces_.insert(kind);
      reload_timer_.start();
    });

    const std::array environments{&surface.ui_};
    LuaUi::commit(environments);
    surfaces_.emplace(&surface, kind);
  }

  void DesktopUi::detach(LuaSurface &surface) {
    surface.ui_.setReloadHandler({});
    surfaces_.erase(&surface);
  }

  void DesktopUi::reloadConfiguration() {
    std::vector<LuaUi *> environments{&configuration_};

    for (const auto &[surface, _] : surfaces_) {
      environments.push_back(&surface->ui_);
    }

    try {
      const QFileInfo config(config_path_);
      const auto source_path = config_required_ || config.exists() || config.isSymLink()
                                   ? config_path_
                                   : QStringLiteral(":/telar/ui/desktop.lua");
      const auto source = readScript(source_path);
      const auto chunk = (QStringLiteral("@") + source_path).toUtf8();
      configuration_.prepare(scriptView(source), scriptView(chunk), config.absolutePath());

      auto settings = configuration_.preparedSettings();
      auto prefix = configuration_.preparedPrefix();

      for (const auto &[surface, kind] : surfaces_) {
        prepareSurface(*surface, kind, settings, prefix);
      }

      LuaUi::commit(environments);
      settings_.swap(settings);
      prefix_.swap(prefix);
      if (changed) {
        changed();
      }
    } catch (...) {
      for (auto *environment : environments) {
        environment->discard();
      }

      throw;
    }
  }

  void DesktopUi::reloadPending() {
    const bool global = std::exchange(configuration_dirty_, false) || retry_configuration_;
    const auto dirty = std::exchange(dirty_surfaces_, {});

    if (global) {
      try {
        watcher_.setPaths({config_path_});
        reloadConfiguration();
        retry_configuration_ = false;
      } catch (const std::exception &error) {
        retry_configuration_ = true;
        qWarning() << "Desktop configuration reload failed:" << error.what();
      }

      return;
    }

    for (const auto kind : dirty) {
      std::vector<LuaUi *> environments;

      try {
        for (const auto &[surface, attached_kind] : surfaces_) {
          if (attached_kind == kind) {
            environments.push_back(&surface->ui_);
            prepareSurface(*surface, kind, settings_, prefix_);
          }
        }

        if (!environments.empty()) {
          LuaUi::commit(environments);
        }
      } catch (const std::exception &error) {
        for (auto *environment : environments) {
          environment->discard();
        }

        qWarning() << surfaceName(kind) << "UI reload failed:" << error.what();
      }
    }
  }

  QVariantMap DesktopUi::options(SurfaceKind kind) const {
    return settings_.value(surfaceName(kind)).toMap().value("options").toMap();
  }

  QRectF DesktopUi::workArea(std::uint32_t display, QRectF available) const {
    for (const auto &[surface, kind] : surfaces_) {
      if (kind != SurfaceKind::topbar && kind != SurfaceKind::sidebar) {
        continue;
      }
      const auto state = surface->nativeState();
      if (!state.value("visible").toBool() ||
          state.value("screen").toMap().value("id").toUInt() != display ||
          options(kind).value("overlay", false).toBool()) {
        continue;
      }
      const auto rect = state.value("geometry").toMap();
      const QRectF occupied(rect.value("x").toDouble(),
                            rect.value("y").toDouble(),
                            rect.value("width").toDouble(),
                            rect.value("height").toDouble());
      if (!available.intersects(occupied)) {
        continue;
      }
      if (kind == SurfaceKind::topbar) {
        available.setTop(std::max(available.top(), occupied.bottom()));
      } else {
        available.setLeft(std::max(available.left(), occupied.right()));
      }
    }
    return available;
  }
} // namespace ui
