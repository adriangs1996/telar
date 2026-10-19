#include "qttopbar.hpp"
#include "lua_vm.hpp"
#include <QColor>
#include <QDir>
#include <QFile>
#include <QString>
#include <chrono>
#include <stdexcept>
#include <string_view>

#define REFRESH_DELAY_MS 200

QtTopBarSurface::QtTopBarSurface(lua::Vm &lua_vm) : QuickSurface(lua_vm) {
  const auto ui_directory = qEnvironmentVariable("TELAR_DESKTOP_UI_DIR");
  script_path_ = ui_directory.isEmpty()
                     ? QStringLiteral(":/telar/ui/topbar.lua")
                     : QDir(ui_directory).absoluteFilePath(QStringLiteral("topbar.lua"));

  window_.setColor(QColor("#263449"));
  text_item_ = &createItem("QtQuick", "Text",
                           {
                               {"text", QString{}},
                               {"color", QColor("#cdd6f4")},
                               {"x", 12},
                               {"y", 8},
                           });

  reload();
  watchScript();
}

void QtTopBarSurface::reload() {
  QFile script(script_path_);
  if (!script.open(QIODevice::ReadOnly)) {
    throw std::runtime_error(script.errorString().toStdString());
  }

  const auto source = script.readAll();
  if (script.error() != QFileDevice::NoError) {
    throw std::runtime_error(script.errorString().toStdString());
  }

  lua_vm.execute(std::string_view{
      source.constData(),
      static_cast<std::size_t>(source.size()),
  });
  const auto text = lua_vm.readGlobalString("topbar_text");
  text_item_->setProperty("text", QString::fromStdString(text));
}

void QtTopBarSurface::watchScript() {
  if (script_path_.startsWith(QStringLiteral(":/"))) {
    return;
  }

  constexpr auto reload_delay = std::chrono::milliseconds{REFRESH_DELAY_MS};
  reload_timer_.setSingleShot(true);
  reload_timer_.setInterval(reload_delay);

  const auto schedule_reload = [this](const QString &) { reload_timer_.start(); };

  QObject::connect(&watcher_, &QFileSystemWatcher::directoryChanged, &reload_timer_,
                   schedule_reload);
  QObject::connect(&watcher_, &QFileSystemWatcher::fileChanged, &reload_timer_, schedule_reload);
  QObject::connect(&reload_timer_, &QTimer::timeout, &reload_timer_, [this] {
    if (QFileInfo::exists(script_path_) && !watcher_.files().contains(script_path_)) {
      if (!watcher_.addPath(script_path_)) {
        qWarning() << "Unable to watch UI script:" << script_path_;
      }
    }
    try {
      reload();
    } catch (const std::exception &error) {
      qWarning() << "UI reload failed:" << error.what();
    }
  });

  const auto failed_paths = watcher_.addPaths({
      script_path_,
      QFileInfo(script_path_).absolutePath(),
  });

  if (!failed_paths.isEmpty()) {
    qWarning() << "Unable to watch UI paths:" << failed_paths;
  }
}
