#include "file_watch.hpp"
#include "../trace.hpp"
#include <QDebug>
#include <QDir>
#include <QFileInfo>
#include <QSet>
#include <stdexcept>
#include <utility>

namespace ui {
  FileWatch::FileWatch(QObject *parent)
      : QObject(parent) {
    QObject::connect(&watcher_,
                     &QFileSystemWatcher::fileChanged,
                     this,
                     [this](const QString &path) {
                       changed(path);
                     });

    QObject::connect(&watcher_,
                     &QFileSystemWatcher::directoryChanged,
                     this,
                     [this](const QString &path) {
                       changed(path);
                     });
  }

  FileWatch::Stamp FileWatch::stamp(const QString &path) {
    const QFileInfo info(path);

    return {info.exists(), info.isDir(), info.size(), info.lastModified()};
  }

  void FileWatch::setCallback(std::function<void(const QStringList &)> callback) {
    callback_ = std::move(callback);
  }

  void FileWatch::setPaths(const QStringList &paths) {
    TELAR_TRACE("ui.file_watch.set_paths");
    QSet<QString> desired;

    for (const auto &path : paths) {
      if (!path.startsWith(QStringLiteral(":"))) {
        desired.insert(QDir::cleanPath(path));
      }
    }

    for (auto it = paths_.begin(); it != paths_.end();) {
      if (!desired.contains(it.key())) {
        it = paths_.erase(it);
      } else {
        ++it;
      }
    }

    for (const auto &path : desired) {
      if (!paths_.contains(path)) {
        paths_.insert(path, stamp(path));
      }
    }

    rearm();
  }

  // Watching the nearest existing ancestor also follows deletion and recreation.
  void FileWatch::rearm() {
    TELAR_TRACE("ui.file_watch.rearm");
    QSet<QString> desired;

    for (auto it = paths_.cbegin(); it != paths_.cend(); ++it) {
      if (QFileInfo::exists(it.key())) {
        desired.insert(it.key());
      }

      auto parent = QFileInfo(it.key()).absolutePath();

      while (!QFileInfo::exists(parent)) {
        const auto next = QFileInfo(parent).absolutePath();

        if (next == parent) {
          break;
        }

        parent = next;
      }

      desired.insert(parent);
    }

    const auto files = watcher_.files();
    const auto directories = watcher_.directories();
    const QSet<QString> current(files.begin(), files.end());
    QSet<QString> all = current;
    all.unite(QSet<QString>(directories.begin(), directories.end()));

    // One call per direction: the macOS backend restarts its event stream on every call.
    QStringList removed, added;
    for (const auto &path : all) {
      if (!desired.contains(path)) {
        removed.append(path);
      }
    }

    for (const auto &path : desired) {
      if (!all.contains(path)) {
        added.append(path);
      }
    }

    if (!removed.isEmpty()) {
      watcher_.removePaths(removed);
    }

    if (!added.isEmpty()) {
      const auto failed = watcher_.addPaths(added);
      if (!failed.isEmpty()) {
        throw std::runtime_error(
            QStringLiteral("Unable to watch: %1").arg(failed.first()).toStdString());
      }
    }
  }

  void FileWatch::changed(const QString &path) {
    TELAR_TRACE("ui.file_watch.changed");
    try {
      QStringList changes;
      const auto files = watcher_.files();
      const auto directories = watcher_.directories();

      for (auto it = paths_.begin(); it != paths_.end(); ++it) {
        const auto next = stamp(it.key());
        const bool dropped =
            next.exists && !(next.directory ? directories : files).contains(it.key());

        if (it.key() == path || next != it.value() || dropped) {
          changes.append(it.key());
        }

        it.value() = next;
      }

      rearm();

      if (!changes.isEmpty() && callback_) {
        callback_(changes);
      }
    } catch (const std::exception &error) {
      qWarning() << "File watcher failed:" << error.what();
    }
  }
} // namespace ui
