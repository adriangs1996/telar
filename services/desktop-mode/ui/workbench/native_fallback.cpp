#include "native.hpp"
#ifndef Q_OS_MACOS
#include <QGuiApplication>
#include <QScreen>
#include <QWindow>

namespace workbench::native {
  Display display(std::uint32_t) {
    if (auto *screen = QGuiApplication::primaryScreen()) {
      return {screen->availableGeometry(), screen->devicePixelRatio()};
    }

    return {};
  }

  void place(QWindow &, std::uint64_t) {}

  void prepareInputWindow(QWindow &) {}

  void commitComposition(QWindow &) {}

  struct WindowObserver::Impl {};

  WindowObserver::WindowObserver(QObject &, Delivery) {}

  WindowObserver::~WindowObserver() = default;

  void WindowObserver::place(std::uint32_t, QRectF) {}

  void WindowObserver::move(std::uint32_t, QPointF) {}

  void WindowObserver::focus(std::uint32_t) {}

  void WindowObserver::close(std::uint32_t) {}
} // namespace workbench::native
#endif
