#include "native.hpp"
#if !defined(Q_OS_MACOS) && !defined(Q_OS_LINUX)
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

  QRect frame(QWindow &window) {
    return window.geometry();
  }

  void setFrame(QWindow &window, QRect frame) {
    window.setGeometry(frame);
  }

  void raise(QWindow &window) {
    window.raise();
  }

  void setVisible(QWindow &window, bool visible) {
    window.setOpacity(visible ? 1 : 0);
  }

  void prepareInputWindow(QWindow &) {}

  void commitComposition(QWindow &) {}

  struct WindowObserver::Impl {};

  WindowObserver::WindowObserver(QObject &, Delivery) {}

  WindowObserver::~WindowObserver() = default;

  void WindowObserver::place(std::uint32_t, std::uint64_t, QRectF) {}

  void WindowObserver::move(std::uint32_t, QPointF) {}

  void WindowObserver::hide(std::uint32_t, std::uint64_t) {}

  void WindowObserver::focus(std::uint32_t) {}

  void WindowObserver::close(std::uint32_t) {}
} // namespace workbench::native
#endif
