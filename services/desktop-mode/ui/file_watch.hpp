#pragma once

#include <QDateTime>
#include <QFileSystemWatcher>
#include <QMap>
#include <QObject>
#include <QStringList>
#include <functional>

namespace ui {
  class FileWatch final : public QObject {
  public:
    explicit FileWatch(QObject *parent = nullptr);
    void setPaths(const QStringList &paths);
    void setCallback(std::function<void(const QStringList &)> callback);

  private:
    struct Stamp {
      bool exists;
      bool directory;
      qint64 size;
      QDateTime modified;

      bool operator==(const Stamp &) const = default;
    };

    QFileSystemWatcher watcher_;
    QMap<QString, Stamp> paths_;
    std::function<void(const QStringList &)> callback_;

    static Stamp stamp(const QString &path);
    void rearm();
    void changed(const QString &path);
  };
} // namespace ui
