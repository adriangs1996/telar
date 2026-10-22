#include "session_log.hpp"
#include "desktop_registry.hpp"
#include "log_categories.hpp"
#include "trace.hpp"
#include <QByteArray>
#include <QDateTime>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QThread>
#include <cstdio>
#include <fcntl.h>
#include <mutex>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#elif defined(__linux__)
#include <fstream>
#endif

namespace telar_log {
  Q_LOGGING_CATEGORY(session, "telar.desktop.session")
  Q_LOGGING_CATEGORY(catalog, "telar.desktop.catalog")
  Q_LOGGING_CATEGORY(spaces, "telar.desktop.spaces")
  Q_LOGGING_CATEGORY(shortcuts, "telar.desktop.shortcuts")
  Q_LOGGING_CATEGORY(workbench, "telar.desktop.workbench")
  Q_LOGGING_CATEGORY(connection, "telar.desktop.connection")
  Q_LOGGING_CATEGORY(frames, "telar.desktop.frames")
  Q_LOGGING_CATEGORY(terminal, "telar.desktop.terminal")
} // namespace telar_log

#if TELAR_DEBUG
namespace {
  constexpr qsizetype retained_logs = 20;
  constexpr qint64 maximum_log_bytes = 64LL * 1024 * 1024;
  // Per-frame traces would bury everything else; QT_LOGGING_RULES turns them on, since the
  // environment overrides these rules.
  constexpr auto default_rules = "telar.*.debug=true\ntelar.desktop.frames.debug=false";

  struct Sink {
    std::mutex mutex;
    std::FILE *file = nullptr;
    qint64 written = 0;
    QtMessageHandler previous = nullptr;
    QElapsedTimer clock;
  };

  Sink sink;

  char level(QtMsgType type) {
    switch (type) {
    case QtDebugMsg:
      return 'D';
    case QtInfoMsg:
      return 'I';
    case QtWarningMsg:
      return 'W';
    case QtCriticalMsg:
      return 'C';
    case QtFatalMsg:
      return 'F';
    }

    return '?';
  }

  // Exclusive and owner-only: a session file never follows or reuses one someone else placed.
  // The latest symlink names the newest file of its kind.
  std::FILE *create(const QDir &directory, const QString &name, const QString &latest) {
    const auto path = QFile::encodeName(directory.filePath(name));
    const int descriptor = ::open(path.constData(),
                                  O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                  S_IRUSR | S_IWUSR);
    if (descriptor < 0) {
      throw std::runtime_error("cannot create a session file");
    }

    auto *file = ::fdopen(descriptor, "w");
    if (!file) {
      ::close(descriptor);
      throw std::runtime_error("cannot open a session file");
    }

    const auto link = QFile::encodeName(directory.filePath(latest));
    ::unlink(link.constData());
    ::symlink(QFile::encodeName(name).constData(), link.constData());
    return file;
  }

  void prune(QDir &directory, const QString &pattern) {
    auto existing = directory.entryList({pattern}, QDir::Files, QDir::Name);
    while (existing.size() >= retained_logs) {
      directory.remove(existing.takeFirst());
    }
  }

  // Each line is flushed at once, so the log survives a crash up to its last message.
  void record(QtMsgType type, const QMessageLogContext &context, const QString &message) {
    {
      std::lock_guard lock(sink.mutex);

      if (sink.file) {
        QByteArray line = QDateTime::currentDateTime().toString(Qt::ISODateWithMs).toUtf8();
        line += " +" + QByteArray::number(static_cast<double>(sink.clock.elapsed()) / 1000, 'f', 3);
        line += ' ';
        line += level(type);
        line += ' ';
        line += context.category ? context.category : "default";
        line += " [" +
                QByteArray::number(reinterpret_cast<quintptr>(QThread::currentThreadId()), 16) +
                "] ";
        line += message.toUtf8();

        if (context.file) {
          line += " (" + QFileInfo(QString::fromUtf8(context.file)).fileName().toUtf8() + ':' +
                  QByteArray::number(context.line) + ')';
        }

        line += '\n';

        if (sink.written + line.size() > maximum_log_bytes) {
          std::fputs("Session log truncated: size limit reached\n", sink.file);
          std::fclose(sink.file);
          sink.file = nullptr;
        } else {
          std::fwrite(line.constData(), 1, static_cast<std::size_t>(line.size()), sink.file);
          std::fflush(sink.file);
          sink.written += line.size();
        }
      }
    }

    // The console keeps showing what it showed before: warnings and worse.
    if (type != QtDebugMsg && type != QtInfoMsg && sink.previous) {
      sink.previous(type, context, message);
    }
  }
} // namespace
#endif

void session_log::open() {
#if TELAR_DEBUG
  QLoggingCategory::setFilterRules(QString::fromLatin1(default_rules));
  QString path;

  try {
    QDir directory(QString::fromStdString(DesktopRegistry::directory() + "/logs"));
    if (!QDir().mkpath(directory.path()) ||
        !QFile::setPermissions(directory.path(),
                               QFileDevice::ReadOwner | QFileDevice::WriteOwner |
                                   QFileDevice::ExeOwner)) {
      throw std::runtime_error("cannot create the log directory");
    }

    prune(directory, QStringLiteral("desktop-*.log"));
    prune(directory, QStringLiteral("desktop-*.trace.json"));
    const auto stem =
        QStringLiteral("desktop-%1-%2")
            .arg(QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd-HHmmss")))
            .arg(::getpid());
    path = directory.filePath(stem + QStringLiteral(".log"));
    sink.file = create(directory, stem + QStringLiteral(".log"), QStringLiteral("latest.log"));

    try {
      trace::open(create(directory,
                         stem + QStringLiteral(".trace.json"),
                         QStringLiteral("latest.trace.json")));
    } catch (const std::exception &error) {
      std::fprintf(stderr, "Telar Desktop: session trace disabled: %s\n", error.what());
    }
  } catch (const std::exception &error) {
    std::fprintf(stderr, "Telar Desktop: session log disabled: %s\n", error.what());
    return;
  }

  sink.clock.start();
  sink.previous = qInstallMessageHandler(record);
  std::fprintf(stderr, "Telar Desktop session log: %s\n", qPrintable(path));
#endif
}

void session_log::close() {
#if TELAR_DEBUG
  trace::close();
  qInstallMessageHandler(sink.previous);
  std::lock_guard lock(sink.mutex);

  if (sink.file) {
    std::fclose(sink.file);
    sink.file = nullptr;
  }
#endif
}

std::size_t session_log::residentBytes() {
#if defined(__APPLE__)
  mach_task_basic_info_data_t info{};
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(),
                MACH_TASK_BASIC_INFO,
                reinterpret_cast<task_info_t>(&info),
                &count) != KERN_SUCCESS) {
    return 0;
  }

  return info.resident_size;
#elif defined(__linux__)
  std::ifstream statm("/proc/self/statm");
  std::size_t size = 0, resident = 0;
  if (!(statm >> size >> resident)) {
    return 0;
  }

  return resident * static_cast<std::size_t>(::sysconf(_SC_PAGESIZE));
#else
  return 0;
#endif
}
