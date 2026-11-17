#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application/dependencies.hpp"
#include "platform/window.hpp"
#include "ui/app/application_controller.hpp"
#include "ui/foundation/fonts/bundled_fonts.hpp"
#include <QDir>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QFont>
#include <QGuiApplication>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickStyle>
#include <QQuickView>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QUrl>
#include <cstdlib>
#include <exception>
#include <iostream>

// Shows a QML file from disk and shows it again whenever a QML file beside it changes.
//
//   gui-playground src/gui/playground/Tiles.qml
//
// The file's root is an Item, which the window sizes to itself; it imports Telar.Gui and
// reaches the GUI's components, and `telar` is an application controller on the default
// configuration, so `telar.colors` and `telar.display.geometry.typography` give a component
// what the window would. src/gui/playground/ is ignored by git: it is the place for these
// files, and for copies of the module's components to try variants of without a rebuild.

namespace {

  using namespace telar::gui;
  using namespace telar::gui::qt;

  constexpr int chrome_font_pixels = 13;
  // Editors save in several writes; one reload follows the last of them.
  constexpr int reload_delay_ms = 50;
  constexpr int initial_width = 800;
  constexpr int initial_height = 600;

  // A file replaced by a rename leaves the watch, and a new file is not in it yet.
  void watch(QFileSystemWatcher& watcher, const QDir& directory) {
    const auto files = directory.entryInfoList({QStringLiteral("*.qml"), QStringLiteral("*.js")}, QDir::Files);

    for (const auto& file : files) {
      watcher.addPath(file.absoluteFilePath());
    }
  }

  int run(const QString& path) {
    QQuickStyle::setStyle(QStringLiteral("Basic"));
    bundledFonts();
    QFont chrome_font{QStringLiteral("IBM Plex Sans")};

    chrome_font.setPixelSize(chrome_font_pixels);
    QGuiApplication::setFont(chrome_font);
    ApplicationMemory application_memory;
    ApplicationAllocator& memory = application_memory.memory();
    ApplicationController client{memory};

    client.loadConfiguration({}, {}, {});
    const QFileInfo file{path};
    const auto source = QUrl::fromLocalFile(file.absoluteFilePath());
    const auto directory = file.absoluteDir();
    QQuickView view;
    QFileSystemWatcher watcher;
    QTimer reload;

    view.engine()->rootContext()->setContextProperty(QStringLiteral("telar"), &client);
    view.setResizeMode(QQuickView::SizeRootObjectToView);
    view.resize(initial_width, initial_height);
    view.setTitle(file.fileName());

    // The cache holds the compiled files; it is cleared once no object made from them is left.
    // Qt reports a file that fails to load on the standard error.
    const auto load = [&] {
      view.setSource({});
      view.engine()->clearComponentCache();
      view.setSource(source);
      watch(watcher, directory);
    };

    reload.setSingleShot(true);
    reload.setInterval(reload_delay_ms);
    QObject::connect(&reload, &QTimer::timeout, load);
    QObject::connect(&watcher, &QFileSystemWatcher::fileChanged, &reload, qOverload<>(&QTimer::start));
    QObject::connect(&watcher, &QFileSystemWatcher::directoryChanged, &reload, qOverload<>(&QTimer::start));
    watcher.addPath(directory.absolutePath());
    load();
    view.show();

    return QGuiApplication::exec();
  }

}

int main(int argc, char** argv) {
  const QGuiApplication application{argc, argv};

  platform::configureGraphics();
  const auto arguments = QGuiApplication::arguments();
  if (arguments.size() != 2) {
    std::cerr << "usage: gui-playground FILE.qml\n";

    return EXIT_FAILURE;
  }

  try {
    return run(arguments.at(1));
  } catch (const std::exception& error) {
    std::cerr << "gui-playground: " << error.what() << '\n';

    return EXIT_FAILURE;
  }
}
