#include "application/dependencies.hpp"
#include "config/callback.hpp"
#include "core/configuration.hpp"
#include "input/action.hpp"
#include "input/configuration.hpp"
#include "qt/configuration_source.hpp"
#include "qt/bundled_fonts.hpp"
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFile>
#include <QGuiApplication>
#include <QTemporaryDir>
#include <QTimer>
#include <QtCore/qbytearray.h>
#include <QtCore/qiodevice.h>
#include <QtCore/qobject.h>
#include <QtCore/qstring.h>
#include <QtCore/qtypes.h>
#include <cstddef>
#include <cstdlib>
#include <exception>
#include <iostream>
#include <stdexcept>

namespace {

using namespace telar::gui;
using namespace telar::gui::qt;

constexpr int module_count = 16;
constexpr qsizetype module_padding_bytes = qsizetype{512} * 1024;
constexpr int reload_timeout_ms = 6000;

void writeFile(const QString &path, const QByteArray &source) {
  QFile file{path};
  if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate) || file.write(source) != source.size()) {
    throw std::runtime_error{"Cannot write configuration benchmark fixture"};
  }
}

void createModules(const QTemporaryDir &directory) {
  const auto source = QByteArray{"--"} + QByteArray{module_padding_bytes, 'x'} + "\nreturn true";
  for (int index = 1; index <= module_count; ++index) {
    writeFile(directory.filePath(QStringLiteral("part%1.lua").arg(index)), source);
  }
}

QByteArray rootSource(bool sidebar_visible) {
  return QStringLiteral("for index=1,%1 do require('part'..index) end; return {api_version=2,client={sidebar={visible=%2},keybindings={telar.bind_global({'s'},function() return telar.action.toggle_sidebar() end)}}}")
      .arg(module_count)
      .arg(sidebar_visible ? QStringLiteral("true") : QStringLiteral("false"))
      .toUtf8();
}

void measure() {
  const QTemporaryDir directory;
  if (!directory.isValid()) {
    throw std::runtime_error{"Cannot create configuration benchmark directory"};
  }

  createModules(directory);
  const auto path = directory.filePath(QStringLiteral("config.lua"));
  writeFile(path, rootSource(false));
  ApplicationAllocator memory;
  ConfigurationSource source{memory};
  source.open({.path = path, .profile = QString{}, .theme = QString{}});
  if (!source.error().isEmpty()) {
    throw std::runtime_error{source.error().toStdString()};
  }

  writeFile(path, rootSource(true));
  QElapsedTimer clock;
  QEventLoop loop;
  QTimer timeout;
  timeout.setSingleShot(true);
  qint64 completion_ns = 0;
  qint64 heartbeat_ns = 0;
  QObject::connect(&source, &ConfigurationSource::changed, &loop, [&] {
    completion_ns = clock.nsecsElapsed();
    loop.quit();
  });
  QObject::connect(&source, &ConfigurationSource::failed, &loop, &QEventLoop::quit);
  QObject::connect(&timeout, &QTimer::timeout, &loop, &QEventLoop::quit);
  timeout.start(reload_timeout_ms);
  clock.start();
  QTimer::singleShot(0, &loop, [&] {
    heartbeat_ns = clock.nsecsElapsed();
  });
  source.poll();
  const auto call_ns = clock.nsecsElapsed();
  if (completion_ns == 0 && source.error().isEmpty()) {
    loop.exec();
  }

  QCoreApplication::processEvents();
  if (completion_ns == 0 || !source.error().isEmpty() || !source.configuration().sidebar_visible) {
    throw std::runtime_error{"The configuration benchmark failed to adopt its generation"};
  }

  const auto effects = source.invoke(source.input().configured[0].action, {});
  if (effects.length != 1 || effects.actions[0].kind != BindingActionKind::toggle_sidebar) {
    throw std::runtime_error{"The configuration benchmark changed its callback result"};
  }

  std::cout << "{\"call_ns\":" << call_ns << ",\"heartbeat_ns\":" << heartbeat_ns << ",\"completion_ns\":" << completion_ns << ",\"sidebar_visible\":true,\"callback\":\"toggle-sidebar\"}\n";
}

}

int main(int argc, char **argv) {
  const QGuiApplication application{argc, argv};
  bundledFonts();

  try {
    measure();
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}
