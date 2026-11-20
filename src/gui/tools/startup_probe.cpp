#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/application_memory.hpp"
#include "ui/app/application_controller.hpp"
#include "ui/kit/fonts/bundled_fonts.hpp"
#include <QFont>
#include <QGuiApplication>
#include <QObject>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QString>
#include <QTimer>
#include <QtCore/qtenvironmentvariables.h>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <iostream>
#include <stdexcept>

// How long the GUI takes to start: from main to the root QML object, and to its first frame.
//
// It builds the window as the GUI tests do (tests/quick_test.cpp), without a runtime, on the
// offscreen platform and the software scene graph, so it never shows a window. It prints one
// JSON line of wall-clock instants in nanoseconds since the Unix epoch; the process's own start
// is the caller's to take, as src/gui/tools/measure_startup.py does, since what runs before
// main (the dynamic loader, static initializers, the QML type registration of static plugins)
// is part of what it measures.

namespace {

  using namespace telar::gui;
  using namespace telar::gui::qt;

  constexpr int chrome_font_pixels = 13;
  constexpr int frame_timeout_ms = 10'000;

  std::int64_t now() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
  }

  struct Instants {
    std::int64_t main = 0;
    std::int64_t application = 0;
    std::int64_t controller = 0;
    std::int64_t root = 0;
    std::int64_t frame = 0;
  };

  void measure(Instants& instants) {
    QQuickStyle::setStyle(QStringLiteral("Basic"));
    bundledFonts();
    QFont chrome_font{QStringLiteral("IBM Plex Sans")};

    chrome_font.setPixelSize(chrome_font_pixels);
    QGuiApplication::setFont(chrome_font);
    ApplicationMemory application_memory;
    ApplicationAllocator& memory = application_memory.memory();
    ApplicationController client{memory};

    client.loadConfiguration({}, {}, {});
    instants.controller = now();
    QQmlApplicationEngine engine;

    engine.rootContext()->setContextProperty(QStringLiteral("telar"), &client);
    engine.loadFromModule(QStringLiteral("Telar.Gui"), QStringLiteral("Main"));
    auto* window = engine.rootObjects().isEmpty() ? nullptr : qobject_cast<QQuickWindow*>(engine.rootObjects().first());
    if (window == nullptr) {
      throw std::runtime_error{"Main did not create a window"};
    }

    instants.root = now();
    QObject::connect(window, &QQuickWindow::frameSwapped, &client, [&instants] {
      if (instants.frame == 0) {
        instants.frame = now();
        QGuiApplication::quit();
      }
    });

    QTimer::singleShot(frame_timeout_ms, &client, [] {
      QGuiApplication::exit(EXIT_FAILURE);
    });

    client.setWindow(*window);
    window->update();
    if (QGuiApplication::exec() != EXIT_SUCCESS || instants.frame == 0) {
      throw std::runtime_error{"The window presented no frame"};
    }
  }

}

int main(int argc, char** argv) {
  Instants instants{.main = now()};

  // Never a window on the desktop, and no GPU timing in the numbers.
  qputenv("QT_QPA_PLATFORM", "offscreen");
  qputenv("QT_QUICK_BACKEND", "software");
  const QGuiApplication application{argc, argv};

  instants.application = now();

  try {
    measure(instants);
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';

    return EXIT_FAILURE;
  }

  std::cout << "{\"main_ns\":" << instants.main << ",\"application_ns\":" << instants.application << ",\"controller_ns\":" << instants.controller << ",\"root_ns\":" << instants.root << ",\"frame_ns\":" << instants.frame << "}\n";

  return EXIT_SUCCESS;
}
