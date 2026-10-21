#include "lua_surface.hpp"
#include "lua_ui.hpp"
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QtGlobal>
#include <chrono>
#include <stdexcept>
#include <string_view>

namespace {
  constexpr auto refresh_delay = std::chrono::milliseconds{200};

  QByteArray readScript(const QString &path) {
    QFile script(path);

    if (!script.open(QIODevice::ReadOnly)) {
      throw std::runtime_error(
          QStringLiteral("%1: %2").arg(path, script.errorString()).toStdString());
    }

    auto source = script.readAll();

    if (script.error() != QFileDevice::NoError) {
      throw std::runtime_error(
          QStringLiteral("%1: %2").arg(path, script.errorString()).toStdString());
    }

    return source;
  }

  std::string_view view(const QByteArray &bytes) {
    return {bytes.constData(), static_cast<std::size_t>(bytes.size())};
  }
} // namespace

LuaSurface::LuaSurface(ui::Services &services, const QSize &size, ui::SurfaceKind kind)
    : kind_(kind),
      ui_(std::make_unique<ui::LuaUi>(services, *this)) {
  ui_->setReloadHandler([this] {
    reload_timer_.start();
  });

  window_.resize(size);
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

  reload();
  watchScript();
}

LuaSurface::~LuaSurface() = default;

void LuaSurface::reload() {
  const auto api_source = readScript(QStringLiteral(":/telar/ui/api.lua"));
  const QFileInfo config(config_path_);

  // Only the topbar runs desktop.lua, which owns the global shortcut configuration.
  // Other surfaces load their own module in an isolated UI environment.
  if (kind_ == ui::SurfaceKind::sidebar) {
    ui_->reload(view(api_source), "require(\"sidebar\")", "@telar/sidebar", config.absolutePath());
    return;
  }

  const auto source_path = config_required_ || config.exists() || config.isSymLink()
                               ? config_path_
                               : QStringLiteral(":/telar/ui/desktop.lua");
  const auto source = readScript(source_path);
  const auto chunk_name = (QStringLiteral("@") + source_path).toUtf8();
  ui_->reload(view(api_source), view(source), view(chunk_name), config.absolutePath());
}

void LuaSurface::watchScript() {
  reload_timer_.setSingleShot(true);
  reload_timer_.setInterval(refresh_delay);
  watcher_.setCallback([this](const QStringList &) {
    reload_timer_.start();
  });

  QObject::connect(&reload_timer_, &QTimer::timeout, &reload_timer_, [this] {
    try {
      rearmWatcher();
      reload();
    } catch (const std::exception &error) {
      const auto name = kind_ == ui::SurfaceKind::topbar ? "topbar" : "sidebar";
      qWarning() << name << "UI reload failed:" << error.what();
    }
  });

  rearmWatcher();
}

void LuaSurface::rearmWatcher() {
  if (kind_ == ui::SurfaceKind::topbar) {
    watcher_.setPaths({config_path_});
  }
}
